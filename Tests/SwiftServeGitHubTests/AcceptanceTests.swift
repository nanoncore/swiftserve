import SwiftServeEvidence
import SwiftServeGitHub
import Testing

@Suite("GitHub App spike acceptance")
struct GitHubAppAcceptanceTests {
    @Test("A signed dependency webhook publishes exactly one correctly mapped Check")
    func signedWebhookToCheck() async throws {
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["Package.resolved"])
        await api.setContent(path: "Package.resolved", ref: fixtureEvent.baseSHA,
                             result: .success(resolved("1.0.0")))
        await api.setContent(path: "Package.resolved", ref: fixtureEvent.headSHA,
                             result: .success(resolved("1.0.1")))
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA, result: .failure(.notFound))
        let orchestrator = GitHubCheckOrchestrator(
            api: api, gate: .block, capabilityDataset: try CapabilityEvidenceLoader.load(),
            generatedAt: { "2026-08-06T12:00:00Z" })
        let secret = "acceptance-secret"
        let body = webhookBody()
        let response = await WebhookHandler(
            secret: secret, queue: ImmediateQueue(orchestrator: orchestrator)).handle(
                eventName: "pull_request",
                signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        let snapshot = await api.snapshot()
        #expect(response == .init(status: 202, code: "accepted"))
        #expect(snapshot.created.count == 1)
        #expect(snapshot.updated.isEmpty)
        #expect(snapshot.created[0].name == CheckPublication.name)
        #expect(snapshot.created[0].conclusion == .success)
        #expect(snapshot.created[0].externalID == fixtureEvent.externalID)
    }
}
