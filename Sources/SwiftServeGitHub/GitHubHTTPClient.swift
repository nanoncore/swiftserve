#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

public final class GitHubHTTPTransport: @unchecked Sendable, InstallationTokenExchanging {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        var request = try makeRequest(path: "/app/installations/\(installationID)/access_tokens", method: "POST")
        request.setValue("Bearer \(appJWT)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        guard response.statusCode == 201 else { throw Self.error(for: response.statusCode) }
        struct Payload: Decodable { let token: String; let expiresAt: String
            enum CodingKeys: String, CodingKey { case token; case expiresAt = "expires_at" }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let expiry = Self.parseDate(payload.expiresAt), !payload.token.isEmpty else {
            throw GitHubAPIError.malformedResponse
        }
        return InstallationToken(value: payload.token, expiresAt: expiry)
    }

    func makeRequest(path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubAPIError.transport
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GitHubAPIError.transport }
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
            guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.transport }
            return (data, http)
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.transport
        }
    }

    static func error(for status: Int) -> GitHubAPIError {
        switch status {
        case 401, 403: .unauthorized
        case 404: .notFound
        default: .rejected(status: status)
        }
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

    public init(transport: GitHubHTTPTransport, tokens: InstallationTokenProvider) {
        self.transport = transport
        self.tokens = tokens
    }

    public func changedFiles(for event: PullRequestEvent, page: Int,
                             perPage: Int) async throws -> Page<ChangedFile> {
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
        return Page(
            values: files.map {
                ChangedFile(filename: $0.filename, status: $0.status,
                            previousFilename: $0.previousFilename)
            },
            hasNext: files.count == perPage)
    }

    public func content(repository: RepositoryCoordinates, path: String, ref: String,
                        installationID: Int64) async throws -> Data {
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
        let data = try await get(path: repoPath(event.repository) + "/pulls/\(event.number)",
                                 installationID: event.installationID)
        struct Pull: Decodable {
            let base: Base
            let head: Head
            struct Base: Decodable { let ref: String; let sha: String }
            struct Head: Decodable { let sha: String }
        }
        guard let pull = try? JSONDecoder().decode(Pull.self, from: data) else {
            throw GitHubAPIError.malformedResponse
        }
        return .init(baseRef: pull.base.ref, baseSHA: pull.base.sha, headSHA: pull.head.sha)
    }

    public func pullRequests(repository: RepositoryCoordinates, baseRef: String,
                             installationID: Int64, page: Int,
                             perPage: Int) async throws -> Page<PullRequestEvent> {
        let data = try await get(
            path: repoPath(repository) + "/pulls",
            query: [.init(name: "state", value: "open"), .init(name: "base", value: baseRef),
                    .init(name: "page", value: String(page)),
                    .init(name: "per_page", value: String(perPage))],
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
        return Page(
            values: pulls.map {
                PullRequestEvent(
                    action: "base_push", installationID: installationID,
                    repository: repository, number: $0.number, baseRef: $0.base.ref,
                    baseSHA: $0.base.sha, headSHA: $0.head.sha)
            },
            hasNext: pulls.count == perPage)
    }

    public func checkRunID(repository: RepositoryCoordinates, headSHA: String, externalID: String,
                           installationID: Int64) async throws -> Int64? {
        let data = try await get(
            path: repoPath(repository) + "/commits/\(headSHA)/check-runs",
            query: [.init(name: "check_name", value: CheckPublication.name),
                    .init(name: "per_page", value: "100")], installationID: installationID)
        struct Listing: Decodable { let checkRuns: [Run]
            struct Run: Decodable { let id: Int64; let externalID: String?
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
                            installationID: Int64) async throws {
        _ = try await send(path: repoPath(repository) + "/check-runs", method: "POST",
                           body: checkBody(publication, includeHeadSHA: true), installationID: installationID,
                           accepted: [201])
    }

    public func updateCheck(repository: RepositoryCoordinates, id: Int64,
                            publication: CheckPublication, installationID: Int64) async throws {
        _ = try await send(path: repoPath(repository) + "/check-runs/\(id)", method: "PATCH",
                           body: checkBody(publication, includeHeadSHA: false), installationID: installationID,
                           accepted: [200])
    }

    private func get(path: String, query: [URLQueryItem] = [], installationID: Int64) async throws -> Data {
        try await send(path: path, query: query, method: "GET", body: nil,
                       installationID: installationID, accepted: [200])
    }

    private func send(path: String, query: [URLQueryItem] = [], method: String,
                      body: [String: Any]?, installationID: Int64,
                      accepted: Set<Int>) async throws -> Data {
        var request = try transport.makeRequest(path: path, query: query, method: method)
        request.setValue("Bearer \(try await tokens.token(for: installationID))",
                         forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await transport.perform(request)
        guard accepted.contains(response.statusCode) else {
            throw GitHubHTTPTransport.error(for: response.statusCode)
        }
        return data
    }

    func checkBody(_ publication: CheckPublication, includeHeadSHA: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "name": publication.name,
            "external_id": publication.externalID,
            "status": "completed",
            "conclusion": publication.conclusion.rawValue,
            "output": ["title": publication.title, "summary": publication.summary],
        ]
        if includeHeadSHA { body["head_sha"] = publication.headSHA }
        return body
    }

    private func repoPath(_ repository: RepositoryCoordinates) -> String {
        "/repos/\(repository.owner)/\(repository.name)"
    }
}
