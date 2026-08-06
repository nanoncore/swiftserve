#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

private final class GitHubRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == origin.scheme?.lowercased(),
              url.host?.lowercased() == origin.host?.lowercased(),
              url.port == origin.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class GitHubHTTPTransport: @unchecked Sendable, InstallationTokenExchanging {
    let baseURL: URL
    let session: URLSession
    private let responseLimit: Int

    public init(baseURL: URL, session: URLSession? = nil,
                connectionTimeout: TimeInterval = 10,
                requestTimeout: TimeInterval = 30,
                responseLimit: Int = 8 << 20) {
        self.baseURL = baseURL
        self.responseLimit = responseLimit
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = connectionTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(
                configuration: configuration,
                delegate: GitHubRedirectDelegate(origin: baseURL),
                delegateQueue: nil)
        }
    }

    public func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        guard installationID > 0 else { throw GitHubAPIError.invalidRequest }
        var request = try makeRequest(path: "/app/installations/\(installationID)/access_tokens", method: "POST")
        request.setValue("Bearer \(appJWT)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        guard response.statusCode == 201 else {
            throw Self.error(for: response, data: data, now: Date())
        }
        struct Payload: Decodable {
            let token: String
            let expiresAt: String
            enum CodingKeys: String, CodingKey { case token; case expiresAt = "expires_at" }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let expiry = Self.parseDate(payload.expiresAt), !payload.token.isEmpty else {
            throw GitHubAPIError.malformedResponse
        }
        return InstallationToken(value: payload.token, expiresAt: expiry)
    }

    func makeRequest(path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains("\0"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubAPIError.invalidRequest
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port else { throw GitHubAPIError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SwiftServe-GitHub-App", forHTTPHeaderField: "User-Agent")
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= responseLimit else { throw GitHubAPIError.responseTooLarge }
            guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.transport }
            return (data, http)
        } catch let error as GitHubAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where [
            .timedOut, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet,
        ].contains(error.code) {
            throw GitHubAPIError.retryable(.init(category: .networkTimeout))
        } catch {
            throw GitHubAPIError.transport
        }
    }

    static func error(for response: HTTPURLResponse, data: Data, now: Date) -> GitHubAPIError {
        let status = response.statusCode
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        if (status == 403 || status == 429), remaining == "0" {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            return .retryable(.init(
                category: .primaryRateLimit,
                notBefore: reset ?? now.addingTimeInterval(60)))
        }
        if status == 429 {
            if response.value(forHTTPHeaderField: "Retry-After") == nil {
                return .retryable(.init(
                    category: .secondaryRateLimit,
                    notBefore: now.addingTimeInterval(60)))
            }
            return .retryable(.init(
                category: .tooManyRequests,
                notBefore: retryDate(response: response, now: now)))
        }
        if status == 403 {
            let message = String(data: data.prefix(4096), encoding: .utf8)?.lowercased() ?? ""
            if response.value(forHTTPHeaderField: "Retry-After") != nil ||
                message.contains("secondary rate limit") || message.contains("abuse detection") {
                return .retryable(.init(
                    category: .secondaryRateLimit,
                    notBefore: retryDate(response: response, now: now) ??
                        now.addingTimeInterval(60)))
            }
            return .forbidden
        }
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 500, 502, 503, 504:
            return .retryable(.init(
                category: .serverError,
                notBefore: retryDate(response: response, now: now)))
        default: return .rejected(status: status)
        }
    }

    private static func retryDate(response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return now.addingTimeInterval(seconds) }
        return parseDate(raw)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public final class GitHubHTTPClient: @unchecked Sendable, GitHubAPI {
    private let transport: GitHubHTTPTransport
    private let tokens: InstallationTokenProvider
    private let now: @Sendable () -> Date

    public init(transport: GitHubHTTPTransport, tokens: InstallationTokenProvider,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    public func changedFiles(for event: PullRequestEvent, page: Int,
                             perPage: Int) async throws -> Page<ChangedFile> {
        try Self.validate(event.repository)
        guard event.number > 0, page > 0, (1...100).contains(perPage) else {
            throw GitHubAPIError.invalidRequest
        }
        let data = try await get(
            path: repoPath(event.repository) + "/pulls/\(event.number)/files",
            query: [.init(name: "page", value: String(page)), .init(name: "per_page", value: String(perPage))],
            installationID: event.installationID)
        struct File: Decodable {
            let filename: String
            let status: String
            let previousFilename: String?
            enum CodingKeys: String, CodingKey {
                case filename, status
                case previousFilename = "previous_filename"
            }
        }
        guard let files = try? JSONDecoder().decode([File].self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        return Page(values: files.map {
            ChangedFile(filename: $0.filename, status: $0.status, previousFilename: $0.previousFilename)
        }, hasNext: files.count == perPage)
    }

    public func content(repository: RepositoryCoordinates, path: String, ref: String,
                        installationID: Int64) async throws -> Data {
        try Self.validate(repository)
        try Self.validatePath(path)
        try Self.validateSHA(ref)
        let data = try await get(
            path: repoPath(repository) + "/contents/\(path)",
            query: [.init(name: "ref", value: ref)], installationID: installationID)
        struct Content: Decodable { let content: String; let encoding: String }
        guard let payload = try? JSONDecoder().decode(Content.self, from: data),
              payload.encoding == "base64",
              let decoded = Data(base64Encoded: payload.content.filter { !$0.isWhitespace }) else {
            throw GitHubAPIError.malformedResponse
        }
        return decoded
    }

    public func currentPullRequest(for event: PullRequestEvent) async throws -> PullRequestState {
        try Self.validate(event.repository)
        guard event.number > 0 else { throw GitHubAPIError.invalidRequest }
        let data = try await get(path: repoPath(event.repository) + "/pulls/\(event.number)",
                                 installationID: event.installationID)
        struct Pull: Decodable {
            let base: Base
            let head: Head
            let changedFiles: Int
            struct Base: Decodable { let ref: String; let sha: String }
            struct Head: Decodable { let sha: String }
            enum CodingKeys: String, CodingKey {
                case base, head
                case changedFiles = "changed_files"
            }
        }
        guard let pull = try? JSONDecoder().decode(Pull.self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        guard pull.changedFiles >= 0 else { throw GitHubAPIError.malformedResponse }
        return .init(baseRef: pull.base.ref, baseSHA: pull.base.sha, headSHA: pull.head.sha,
                     changedFileCount: pull.changedFiles)
    }

    public func pullRequests(repository: RepositoryCoordinates, baseRef: String,
                             installationID: Int64, page: Int,
                             perPage: Int) async throws -> Page<PullRequestEvent> {
        try Self.validate(repository)
        guard page > 0, (1...100).contains(perPage), Self.safeParameter(baseRef) else {
            throw GitHubAPIError.invalidRequest
        }
        let data = try await get(
            path: repoPath(repository) + "/pulls",
            query: [.init(name: "state", value: "open"), .init(name: "base", value: baseRef),
                    .init(name: "page", value: String(page)), .init(name: "per_page", value: String(perPage))],
            installationID: installationID)
        struct Pull: Decodable {
            let number: Int
            let base: Base
            let head: Head
            struct Base: Decodable { let ref: String; let sha: String }
            struct Head: Decodable { let sha: String }
        }
        guard let pulls = try? JSONDecoder().decode([Pull].self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        return Page(values: pulls.map {
            PullRequestEvent(action: "base_push", installationID: installationID,
                             repository: repository, number: $0.number, baseRef: $0.base.ref,
                             baseSHA: $0.base.sha, headSHA: $0.head.sha)
        }, hasNext: pulls.count == perPage)
    }

    public func checkRunID(repository: RepositoryCoordinates, headSHA: String, externalID: String,
                           installationID: Int64) async throws -> Int64? {
        try Self.validate(repository)
        try Self.validateSHA(headSHA)
        guard Self.safeParameter(externalID) else { throw GitHubAPIError.invalidRequest }
        let data = try await get(
            path: repoPath(repository) + "/commits/\(headSHA)/check-runs",
            query: [.init(name: "check_name", value: CheckPublication.name),
                    .init(name: "per_page", value: "100")], installationID: installationID)
        struct Listing: Decodable {
            let checkRuns: [Run]
            struct Run: Decodable {
                let id: Int64
                let externalID: String?
                enum CodingKeys: String, CodingKey { case id; case externalID = "external_id" }
            }
            enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        return listing.checkRuns.first(where: { $0.externalID == externalID })?.id
    }

    public func createCheck(repository: RepositoryCoordinates, publication: CheckPublication,
                            installationID: Int64) async throws -> Int64 {
        try Self.validate(repository)
        try Self.validateSHA(publication.headSHA)
        let data = try await send(path: repoPath(repository) + "/check-runs", method: "POST",
                                  body: checkBody(publication, includeHeadSHA: true),
                                  installationID: installationID, accepted: [201])
        struct Created: Decodable { let id: Int64 }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        return created.id
    }

    public func updateCheck(repository: RepositoryCoordinates, id: Int64,
                            publication: CheckPublication, installationID: Int64) async throws {
        try Self.validate(repository)
        guard id > 0 else { throw GitHubAPIError.invalidRequest }
        _ = try await send(path: repoPath(repository) + "/check-runs/\(id)", method: "PATCH",
                           body: checkBody(publication, includeHeadSHA: false),
                           installationID: installationID, accepted: [200])
    }

    private func get(path: String, query: [URLQueryItem] = [], installationID: Int64) async throws -> Data {
        try await send(path: path, query: query, method: "GET", body: nil,
                       installationID: installationID, accepted: [200])
    }

    private func send(path: String, query: [URLQueryItem] = [], method: String,
                      body: [String: Any]?, installationID: Int64,
                      accepted: Set<Int>) async throws -> Data {
        guard installationID > 0 else { throw GitHubAPIError.invalidRequest }
        var refreshed = false
        while true {
            let token = try await tokens.token(for: installationID)
            var request = try transport.makeRequest(path: path, query: query, method: method)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            }
            let (data, response) = try await transport.perform(request)
            if response.statusCode == 401, !refreshed {
                refreshed = true
                await tokens.invalidate(installationID: installationID, token: token)
                continue
            }
            guard accepted.contains(response.statusCode) else {
                throw GitHubHTTPTransport.error(for: response, data: data, now: now())
            }
            return data
        }
    }

    func checkBody(_ publication: CheckPublication, includeHeadSHA: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "name": publication.name,
            "external_id": publication.externalID,
            "status": publication.status.rawValue,
            "output": ["title": publication.title, "summary": publication.summary],
        ]
        if let conclusion = publication.conclusion { body["conclusion"] = conclusion.rawValue }
        if includeHeadSHA { body["head_sha"] = publication.headSHA }
        return body
    }

    private func repoPath(_ repository: RepositoryCoordinates) -> String {
        "/repos/\(repository.owner)/\(repository.name)"
    }

    private static func validate(_ repository: RepositoryCoordinates) throws {
        guard repository.id > 0, safeRepositoryComponent(repository.owner),
              safeRepositoryComponent(repository.name) else { throw GitHubAPIError.invalidRequest }
    }

    private static func safeRepositoryComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }

    private static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), path.utf8.count <= 4096, !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 }) else {
            throw GitHubAPIError.invalidRequest
        }
    }

    private static func validateSHA(_ sha: String) throws {
        guard [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else {
            throw GitHubAPIError.invalidRequest
        }
    }

    private static func safeParameter(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
    }
}
