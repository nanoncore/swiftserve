import Foundation
import SwiftServeEvidence
import SwiftServeGitHub
import Testing

@Suite("Durable GitHub job store")
struct JobStoreTests {
    func temporaryPath(_ name: String = #function) -> String {
        NSTemporaryDirectory() + "/swiftserve-\(name)-\(UUID().uuidString).sqlite"
    }

    @Test("Duplicate delivery and immutable work identity create one durable job")
    func duplicateDelivery() async throws {
        let store = try SQLiteJobStore(path: temporaryPath())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try await store.enqueue(deliveryID: "delivery-1", job: .pullRequest(fixtureEvent),
                                        now: now, retention: 100) == .inserted)
        #expect(try await store.enqueue(deliveryID: "delivery-1", job: .pullRequest(fixtureEvent),
                                        now: now, retention: 100) == .duplicate)
        #expect(try await store.enqueue(deliveryID: "delivery-redelivery", job: .pullRequest(fixtureEvent),
                                        now: now, retention: 100) == .duplicate)
        #expect(try await store.queueDepth() == 1)
    }

    @Test("Concurrent workers cannot claim one lease")
    func exclusiveClaim() async throws {
        let store = try SQLiteJobStore(path: temporaryPath())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.enqueue(deliveryID: "delivery-1", job: .pullRequest(fixtureEvent),
                                    now: now, retention: 100)
        async let first = store.claim(leaseOwner: "worker-a", now: now,
                                      leaseDuration: 30, excludingInstallations: [])
        async let second = store.claim(leaseOwner: "worker-b", now: now,
                                       leaseDuration: 30, excludingInstallations: [])
        let claimed = try await [first, second].compactMap { $0 }
        #expect(claimed.count == 1)
        #expect(claimed[0].attemptCount == 1)
    }

    @Test("Restart resumes acknowledged work and expired leases recover")
    func restartAndLeaseRecovery() async throws {
        let path = temporaryPath()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstProcess = try SQLiteJobStore(path: path)
        _ = try await firstProcess.enqueue(
            deliveryID: "delivery-1", job: .pullRequest(fixtureEvent), now: now, retention: 100)

        let restarted = try SQLiteJobStore(path: path)
        let firstLease = try #require(try await restarted.claim(
            leaseOwner: "crashed-worker", now: now, leaseDuration: 10,
            excludingInstallations: []))
        #expect(firstLease.attemptCount == 1)
        #expect(try await restarted.claim(
            leaseOwner: "too-early", now: now.addingTimeInterval(9),
            leaseDuration: 10, excludingInstallations: []) == nil)
        let recovered = try #require(try await restarted.claim(
            leaseOwner: "replacement-worker", now: now.addingTimeInterval(11),
            leaseDuration: 10, excludingInstallations: []))
        #expect(recovered.id == firstLease.id)
        #expect(recovered.attemptCount == 2)
    }

    @Test("New head supersedes queued and running older work")
    func supersedingHead() async throws {
        let store = try SQLiteJobStore(path: temporaryPath())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.enqueue(deliveryID: "old-delivery", job: .pullRequest(fixtureEvent),
                                    now: now, retention: 100)
        let old = try #require(try await store.claim(
            leaseOwner: "old-worker", now: now, leaseDuration: 30,
            excludingInstallations: []))
        let newerEvent = PullRequestEvent(
            action: "synchronize", installationID: fixtureEvent.installationID,
            repository: fixtureEvent.repository, number: fixtureEvent.number,
            baseRef: fixtureEvent.baseRef, baseSHA: fixtureEvent.baseSHA,
            headSHA: "new-head-sha")
        _ = try await store.enqueue(deliveryID: "new-delivery", job: .pullRequest(newerEvent),
                                    now: now.addingTimeInterval(1), retention: 100)
        await #expect(throws: SafeDiagnostic.self) {
            try await store.complete(jobID: old.id, leaseOwner: "old-worker",
                                     now: now, retention: 100)
        }
        let current = try #require(try await store.claim(
            leaseOwner: "new-worker", now: now.addingTimeInterval(1),
            leaseDuration: 30, excludingInstallations: []))
        guard case .pullRequest(let currentEvent) = current.job else {
            Issue.record("Expected pull request job")
            return
        }
        #expect(currentEvent.headSHA == newerEvent.headSHA)
        #expect(currentEvent.baseSHA == newerEvent.baseSHA)
        #expect(try await store.queueDepth() == 1)
    }

    @Test("Completed idempotency records expire under bounded retention")
    func retention() async throws {
        let store = try SQLiteJobStore(path: temporaryPath())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.enqueue(deliveryID: "delivery-1", job: .pullRequest(fixtureEvent),
                                    now: now, retention: 60)
        let job = try #require(try await store.claim(
            leaseOwner: "worker", now: now, leaseDuration: 30,
            excludingInstallations: []))
        try await store.complete(jobID: job.id, leaseOwner: "worker", now: now, retention: 60)
        #expect(try await store.prune(now: now.addingTimeInterval(59)) == 0)
        #expect(try await store.prune(now: now.addingTimeInterval(61)) == 1)
        #expect(try await store.enqueue(deliveryID: "delivery-1", job: .pullRequest(fixtureEvent),
                                        now: now.addingTimeInterval(62), retention: 60) == .inserted)
    }

    @Test("Only orchestration metadata reaches persistent storage")
    func privacyBoundary() async throws {
        let path = temporaryPath()
        let store = try SQLiteJobStore(path: path)
        let queue = DurableJobQueue(store: store, retention: 100)
        let body = webhookBody(sender: "RAW-PAYLOAD-SENTINEL")
        let secret = "WEBHOOK-SECRET-SENTINEL"
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request", deliveryID: "privacy-delivery",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response.code == "accepted")
        var persisted = Data()
        for suffix in ["", "-wal", "-shm"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) { persisted += data }
        }
        let raw = String(decoding: persisted, as: UTF8.self)
        #expect(!raw.contains("RAW-PAYLOAD-SENTINEL"))
        #expect(!raw.contains("WEBHOOK-SECRET-SENTINEL"))
        #expect(!raw.contains("LOCKFILE-CONTENT-SENTINEL"))
        #expect(!raw.contains("INSTALLATION-TOKEN-SENTINEL"))
        #expect(SQLiteJobStore.migrationNames == ["v1_create_jobs"])
    }

    @Test("Retry policy is bounded, jittered, and honors server deadlines")
    func retryPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = DurableRetryPolicy(maxAttempts: 3, maxElapsed: 100,
                                        baseDelay: 2, maximumDelay: 20, jitter: { 1 })
        let stored = StoredJob(
            id: "id", deliveryID: "delivery", job: .pullRequest(fixtureEvent),
            checkRunID: nil, attemptCount: 2, state: .running,
            createdAt: now.addingTimeInterval(-10), scheduledAt: now, leaseExpiresAt: nil)
        #expect(policy.nextSchedule(
            for: stored, directive: .init(category: .serverError), now: now) ==
            now.addingTimeInterval(4))
        #expect(policy.nextSchedule(
            for: stored,
            directive: .init(category: .primaryRateLimit,
                             notBefore: now.addingTimeInterval(30)), now: now) ==
            now.addingTimeInterval(30))
        let exhausted = StoredJob(
            id: stored.id, deliveryID: stored.deliveryID, job: stored.job,
            checkRunID: nil, attemptCount: 3, state: .running,
            createdAt: stored.createdAt, scheduledAt: now, leaseExpiresAt: nil)
        #expect(policy.nextSchedule(
            for: exhausted, directive: .init(category: .serverError), now: now) == nil)
    }

    @Test("Worker readiness follows startup and graceful shutdown")
    func readinessAndShutdown() async throws {
        let store = try SQLiteJobStore(path: temporaryPath())
        let orchestrator = GitHubCheckOrchestrator(
            api: FakeGitHubAPI(), capabilityDataset: try CapabilityEvidenceLoader.load())
        let pool = DurableWorkerPool(
            store: store, orchestrator: orchestrator, metrics: OperationalMetrics(),
            capacity: 2, perInstallationCapacity: 1, leaseDuration: 30,
            retention: 60, retryPolicy: .init())
        #expect(await pool.isReady() == false)
        await pool.start()
        #expect(await pool.isReady() == true)
        await pool.shutdown()
        #expect(await pool.isReady() == false)
        #expect(await store.isReady())
    }
}
