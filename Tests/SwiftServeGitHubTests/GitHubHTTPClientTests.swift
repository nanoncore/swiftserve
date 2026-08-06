#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import Testing
@testable import SwiftServeGitHub

@Suite("GitHub HTTP request construction")
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
            return Data(body.utf8)
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
}

private final class GitHubStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw GitHubAPIError.transport }
            let data = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
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
