import Foundation
import SwiftServeEvidence
import SwiftServeGitHub
import Testing

@Suite("GitHub App acceptance")
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
                deliveryID: "acceptance-delivery",
                signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        let snapshot = await api.snapshot()
        #expect(response == .init(status: 202, code: "accepted"))
        #expect(snapshot.created.count == 1)
        #expect(snapshot.updated.count == 1)
        #expect(snapshot.created[0].name == CheckPublication.name)
        #expect(snapshot.created[0].status == .inProgress)
        #expect(snapshot.updated[0].conclusion == .success)
        #expect(snapshot.created[0].externalID == fixtureEvent.externalID)
    }

    @Test("Durable multi-lockfile webhook survives restart, rate limit, and redelivery")
    func durableMVP() async throws {
        let path = NSTemporaryDirectory() + "/swiftserve-mvp-\(UUID().uuidString).sqlite"
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let firstStore = try SQLiteJobStore(path: path)
        let queue = DurableJobQueue(store: firstStore, retention: 3_600, now: clock.now)
        let secret = "mvp-acceptance-secret"
        let body = webhookBody()
        let signature = WebhookSignatureVerifier.signature(secret: secret, body: body)
        let handler = WebhookHandler(secret: secret, queue: queue)

        #expect(await handler.handle(
            eventName: "pull_request", deliveryID: "mvp-delivery",
            signature: signature, body: body).code == "accepted")
        #expect(await handler.handle(
            eventName: "pull_request", deliveryID: "mvp-delivery",
            signature: signature, body: body).code == "accepted")
        #expect(try await firstStore.queueDepth() == 1)

        // Simulate a process restart after the 202 response and before work.
        let restartedStore = try SQLiteJobStore(path: path)
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["Z/Package.resolved", "A/Package.resolved"])
        for lockfile in ["A/Package.resolved", "Z/Package.resolved"] {
            await api.setContent(path: lockfile, ref: fixtureEvent.baseSHA,
                                 result: .success(resolved("1.0.0")))
            await api.setContent(path: lockfile, ref: fixtureEvent.headSHA,
                                 result: .success(resolved("1.0.1")))
        }
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                             result: .failure(.notFound))
        await api.failNextChangedFiles(with: .retryable(.init(
            category: .primaryRateLimit,
            notBefore: clock.now().addingTimeInterval(5))))
        let orchestrator = GitHubCheckOrchestrator(
            api: api, gate: .block, capabilityDataset: try CapabilityEvidenceLoader.load(),
            generatedAt: { "2026-08-06T12:00:00Z" })
        let metrics = OperationalMetrics()
        let workers = DurableWorkerPool(
            store: restartedStore, orchestrator: orchestrator, metrics: metrics,
            capacity: 2, perInstallationCapacity: 1, leaseDuration: 30,
            retention: 3_600,
            retryPolicy: .init(maxAttempts: 4, maxElapsed: 60,
                               baseDelay: 1, maximumDelay: 10, jitter: { 1 }),
            now: clock.now)

        await workers.runOnce()
        await workers.waitForQuiescence()
        #expect(try await restartedStore.queueDepth() == 1)
        #expect(await api.snapshot().created.count == 1)

        clock.advance(by: 6)
        await workers.runOnce()
        await workers.waitForQuiescence()
        let snapshot = await api.snapshot()
        #expect(try await restartedStore.queueDepth() == 0)
        #expect(snapshot.created.count == 1)
        #expect(snapshot.updated.filter { $0.status == .completed }.count == 1)
        #expect(snapshot.updated.last?.title.contains("2 lockfiles") == true)
        #expect(snapshot.updated.last?.summary.contains("A/Package.resolved") == true)
        #expect(snapshot.updated.last?.summary.contains("Z/Package.resolved") == true)
        let counters = await metrics.snapshot(queueDepth: 0)
        #expect(counters.retriedJobs == 1)
        #expect(counters.rateLimitWaits == 1)
        #expect(counters.completedJobs == 1)
    }
}
