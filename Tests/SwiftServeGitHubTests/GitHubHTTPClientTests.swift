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
}

private struct FakeHTTPSigner: AppJWTSigning {
    func token(now: Date) throws -> String { "jwt" }
}

private struct FakeHTTPExchanger: InstallationTokenExchanging {
    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        InstallationToken(value: "token", expiresAt: Date.distantFuture)
    }
}
