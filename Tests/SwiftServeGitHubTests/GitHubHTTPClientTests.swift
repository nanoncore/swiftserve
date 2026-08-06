#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import Testing
@testable import SwiftServeGitHub

@Suite("GitHub HTTP request construction", .serialized)
struct GitHubHTTPClientTests {
    @Test("Repository content paths are encoded exactly once")
    func pathEncoding() throws {
        let transport = GitHubHTTPTransport(baseURL: URL(string: "https://api.github.test/v3")!)
        let request = try transport.makeRequest(path: "/repos/acme/demo/contents/A Folder/Package.resolved")
        #expect(request.url?.absoluteString ==
                "https://api.github.test/v3/repos/acme/demo/contents/A%20Folder/Package.resolved")
    }

    @Test("Update payload excludes the create-only head SHA")
    func updatePayload() throws {
        let transport = GitHubHTTPTransport(baseURL: URL(string: "https://api.github.test")!)
        let provider = InstallationTokenProvider(signer: FakeHTTPSigner(), exchanger: FakeHTTPExchanger())
        let client = GitHubHTTPClient(transport: transport, tokens: provider)
        let publication = CheckPublication(
            headSHA: "abc", externalID: "stable", conclusion: .success,
            title: "Receipt", summary: "Markdown")
        #expect(client.checkBody(publication, includeHeadSHA: true)["head_sha"] as? String == "abc")
        #expect(client.checkBody(publication, includeHeadSHA: false)["head_sha"] == nil)
    }

    @Test("GitHub response models preserve file lifecycle and immutable PR state")
    func responseModels() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubURLProtocol.self]
        let transport = GitHubHTTPTransport(
            baseURL: URL(string: "https://api.github.test")!,
            session: URLSession(configuration: configuration))
        let provider = InstallationTokenProvider(
            signer: FakeHTTPSigner(), exchanger: FakeHTTPExchanger())
        let client = GitHubHTTPClient(transport: transport, tokens: provider)
        GitHubStubURLProtocol.handler = { request in
            let body: String
            switch request.url?.path {
            case "/repos/acme/demo/pulls/7/files":
                body = """
                [{"filename":"New/Package.resolved","status":"renamed","previous_filename":"Old/Package.resolved"}]
                """
            case "/repos/acme/demo/pulls/7":
                body = """
                {"base":{"ref":"main","sha":"base-sha"},"head":{"sha":"head-sha"}}
                """
            case "/repos/acme/demo/pulls":
                body = """
                [{"number":7,"base":{"ref":"main","sha":"base-sha"},"head":{"sha":"head-sha"}}]
                """
            default:
                throw GitHubAPIError.notFound
            }
            return (200, [:], Data(body.utf8))
        }
        defer { GitHubStubURLProtocol.handler = nil }

        let files = try await client.changedFiles(for: fixtureEvent, page: 1, perPage: 100)
        #expect(files.values == [
            ChangedFile(filename: "New/Package.resolved", status: "renamed",
                        previousFilename: "Old/Package.resolved"),
        ])
        #expect(try await client.currentPullRequest(for: fixtureEvent) == .init(
            baseRef: "main", baseSHA: "base-sha", headSHA: "head-sha"))
        let pulls = try await client.pullRequests(
            repository: fixtureEvent.repository, baseRef: "main",
            installationID: fixtureEvent.installationID, page: 1, perPage: 100)
        #expect(pulls.values == [PullRequestEvent(
            action: "base_push", installationID: fixtureEvent.installationID,
            repository: fixtureEvent.repository, number: 7, baseRef: "main",
            baseSHA: "base-sha", headSHA: "head-sha")])
    }

    @Test("One 401 invalidates and refreshes an installation token exactly once")
    func refreshAfter401() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubURLProtocol.self]
        let transport = GitHubHTTPTransport(
            baseURL: URL(string: "https://api.github.test")!,
            session: URLSession(configuration: configuration))
        let exchanger = CountingHTTPExchanger()
        let provider = InstallationTokenProvider(signer: FakeHTTPSigner(), exchanger: exchanger)
        let client = GitHubHTTPClient(transport: transport, tokens: provider)
        let attempts = AttemptCounter()
        GitHubStubURLProtocol.handler = { _ in
            let attempt = attempts.next()
            if attempt == 1 { return (401, [:], Data("credential rejected".utf8)) }
            return (200, [:], Data("""
            {"base":{"ref":"main","sha":"base-sha"},"head":{"sha":"head-sha"}}
            """.utf8))
        }
        defer { GitHubStubURLProtocol.handler = nil }
        _ = try await client.currentPullRequest(for: fixtureEvent)
        #expect(await exchanger.count() == 2)
        #expect(attempts.value == 2)
    }

    @Test("Rate limits, server failures, and permanent failures are classified")
    func retryClassification() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://api.github.test")!, statusCode: status,
                            httpVersion: nil, headerFields: headers)!
        }
        #expect(GitHubHTTPTransport.error(
            for: response(429, ["Retry-After": "12"]), data: Data(), now: now) ==
            .retryable(.init(category: .tooManyRequests,
                             notBefore: now.addingTimeInterval(12))))
        #expect(GitHubHTTPTransport.error(
            for: response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000030"]),
            data: Data(), now: now) ==
            .retryable(.init(category: .primaryRateLimit,
                             notBefore: now.addingTimeInterval(30))))
        #expect(GitHubHTTPTransport.error(
            for: response(403), data: Data("secondary rate limit".utf8), now: now) ==
            .retryable(.init(category: .secondaryRateLimit)))
        #expect(GitHubHTTPTransport.error(for: response(503), data: Data(), now: now) ==
                .retryable(.init(category: .serverError)))
        #expect(GitHubHTTPTransport.error(for: response(403), data: Data(), now: now) == .forbidden)
        #expect(GitHubHTTPTransport.error(for: response(404), data: Data(), now: now) == .notFound)
    }

    @Test("Timeouts are retryable and response limits fail closed")
    func timeoutAndResponseLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubURLProtocol.self]
        let transport = GitHubHTTPTransport(
            baseURL: URL(string: "https://api.github.test")!,
            session: URLSession(configuration: configuration), responseLimit: 8)
        let provider = InstallationTokenProvider(signer: FakeHTTPSigner(), exchanger: FakeHTTPExchanger())
        let client = GitHubHTTPClient(transport: transport, tokens: provider)
        GitHubStubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.currentPullRequest(for: fixtureEvent)
            Issue.record("Expected timeout classification")
        } catch GitHubAPIError.retryable(let directive) {
            #expect(directive.category == .networkTimeout)
        }
        GitHubStubURLProtocol.handler = { _ in (200, [:], Data(repeating: 65, count: 9)) }
        await #expect(throws: GitHubAPIError.responseTooLarge) {
            try await client.currentPullRequest(for: fixtureEvent)
        }
        GitHubStubURLProtocol.handler = nil
    }

    @Test("Repository paths and immutable SHAs are validated before transport")
    func invalidInputs() async {
        let transport = GitHubHTTPTransport(baseURL: URL(string: "https://api.github.test")!)
        let provider = InstallationTokenProvider(signer: FakeHTTPSigner(), exchanger: FakeHTTPExchanger())
        let client = GitHubHTTPClient(transport: transport, tokens: provider)
        await #expect(throws: GitHubAPIError.invalidRequest) {
            try await client.content(repository: fixtureEvent.repository, path: "../Package.resolved",
                                     ref: String(repeating: "a", count: 40), installationID: 99)
        }
        await #expect(throws: GitHubAPIError.invalidRequest) {
            try await client.content(repository: fixtureEvent.repository, path: "Package.resolved",
                                     ref: "main", installationID: 99)
        }
    }
}

private final class GitHubStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw GitHubAPIError.transport }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: headers.merging(["Content-Type": "application/json"]) { first, _ in first })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FakeHTTPSigner: AppJWTSigning {
    func token(now: Date) throws -> String { "jwt" }
}

private struct FakeHTTPExchanger: InstallationTokenExchanging {
    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        InstallationToken(value: "token", expiresAt: Date.distantFuture)
    }
}

private actor CountingHTTPExchanger: InstallationTokenExchanging {
    private var calls = 0
    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        calls += 1
        return .init(value: "token-\(calls)", expiresAt: .distantFuture)
    }
    func count() -> Int { calls }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
