import Foundation

public struct OperationalSnapshot: Codable, Sendable, Equatable {
    public let acceptedWebhooks: Int
    public let rejectedWebhooks: Int
    public let queueDepth: Int
    public let activeJobs: Int
    public let completedJobs: Int
    public let failedJobs: Int
    public let retriedJobs: Int
    public let supersededJobs: Int
    public let rateLimitWaits: Int
    public let publishedChecks: Int
    public let totalPublicationLatencyMilliseconds: Int64
}

public actor OperationalMetrics {
    private var acceptedWebhooks = 0
    private var rejectedWebhooks = 0
    private var activeJobs = 0
    private var completedJobs = 0
    private var failedJobs = 0
    private var retriedJobs = 0
    private var supersededJobs = 0
    private var rateLimitWaits = 0
    private var publishedChecks = 0
    private var totalPublicationLatencyMilliseconds: Int64 = 0

    public init() {}

    public func webhookAccepted() { acceptedWebhooks += 1 }
    public func webhookRejected() { rejectedWebhooks += 1 }
    public func jobStarted() { activeJobs += 1 }
    public func jobCompleted(latency: TimeInterval, publishedCheckCount: Int) {
        activeJobs = max(0, activeJobs - 1)
        completedJobs += 1
        publishedChecks += publishedCheckCount
        totalPublicationLatencyMilliseconds += Int64(max(0, latency) * 1_000) *
            Int64(publishedCheckCount)
    }
    public func jobFailed() { activeJobs = max(0, activeJobs - 1); failedJobs += 1 }
    public func jobRetried(rateLimited: Bool) {
        activeJobs = max(0, activeJobs - 1)
        retriedJobs += 1
        if rateLimited { rateLimitWaits += 1 }
    }
    public func jobSuperseded() { activeJobs = max(0, activeJobs - 1); supersededJobs += 1 }
    public func jobReleased() { activeJobs = max(0, activeJobs - 1) }

    public func snapshot(queueDepth: Int) -> OperationalSnapshot {
        .init(acceptedWebhooks: acceptedWebhooks, rejectedWebhooks: rejectedWebhooks,
              queueDepth: queueDepth, activeJobs: activeJobs,
              completedJobs: completedJobs, failedJobs: failedJobs,
              retriedJobs: retriedJobs, supersededJobs: supersededJobs,
              rateLimitWaits: rateLimitWaits, publishedChecks: publishedChecks,
              totalPublicationLatencyMilliseconds: totalPublicationLatencyMilliseconds)
    }
}

public actor DurableJobQueue: WebhookJobEnqueuing {
    private let store: any JobStore
    private let retention: TimeInterval
    private let metrics: OperationalMetrics?
    private let now: @Sendable () -> Date
    private var accepting = true

    public init(store: any JobStore, retention: TimeInterval,
                metrics: OperationalMetrics? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.retention = retention
        self.metrics = metrics
        self.now = now
    }

    public func enqueue(deliveryID: String, job: WebhookJob) async -> Bool {
        guard accepting else { return false }
        do {
            _ = try await store.enqueue(deliveryID: deliveryID, job: job,
                                        now: now(), retention: retention)
            return true
        } catch {
            return false
        }
    }

    public func stopAccepting() { accepting = false }
    public func startAccepting() { accepting = true }
    public func isAccepting() -> Bool { accepting }
}

public actor DurableWorkerPool {
    private let store: any JobStore
    private let orchestrator: GitHubCheckOrchestrator
    private let metrics: OperationalMetrics
    private let capacity: Int
    private let perInstallationCapacity: Int
    private let leaseDuration: TimeInterval
    private let retention: TimeInterval
    private let retryPolicy: DurableRetryPolicy
    private let now: @Sendable () -> Date
    private var scheduler: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeByInstallation: [Int64: Int] = [:]
    private var stopping = false
    private var started = false
    private var nextPruneAt: Date?

    public init(store: any JobStore, orchestrator: GitHubCheckOrchestrator,
                metrics: OperationalMetrics, capacity: Int,
                perInstallationCapacity: Int, leaseDuration: TimeInterval,
                retention: TimeInterval, retryPolicy: DurableRetryPolicy,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.orchestrator = orchestrator
        self.metrics = metrics
        self.capacity = capacity
        self.perInstallationCapacity = perInstallationCapacity
        self.leaseDuration = leaseDuration
        self.retention = retention
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func start() {
        guard !started else { return }
        started = true
        stopping = false
        nextPruneAt = now()
        scheduler = Task { await self.runLoop() }
    }

    public func runOnce() async {
        await fillCapacity()
    }

    public func waitUntilIdle(maxYields: Int = 10_000) async {
        for _ in 0..<maxYields {
            if tasks.isEmpty, (try? await store.queueDepth()) == 0 { return }
            await Task.yield()
        }
    }

    public func waitForQuiescence(maxYields: Int = 10_000) async {
        for _ in 0..<maxYields {
            if tasks.isEmpty { return }
            await Task.yield()
        }
    }

    public func shutdown() async {
        stopping = true
        let schedulerTask = scheduler
        schedulerTask?.cancel()
        scheduler = nil
        await schedulerTask?.value
        let active = Array(tasks.values)
        active.forEach { $0.cancel() }
        for task in active { await task.value }
        tasks.removeAll()
        activeByInstallation.removeAll()
        started = false
    }

    public func isReady() async -> Bool {
        guard started, !stopping else { return false }
        return await store.isReady()
    }

    private func runLoop() async {
        while !stopping && !Task.isCancelled {
            if nextPruneAt.map({ now() >= $0 }) ?? true {
                _ = try? await store.prune(now: now())
                nextPruneAt = now().addingTimeInterval(3_600)
            }
            await fillCapacity()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func fillCapacity() async {
        while !stopping, tasks.count < capacity {
            let excluded = Set(activeByInstallation.compactMap {
                $0.value >= perInstallationCapacity ? $0.key : nil
            })
            let owner = UUID().uuidString
            let job: StoredJob?
            do {
                job = try await store.claim(leaseOwner: owner, now: now(),
                                            leaseDuration: leaseDuration,
                                            excludingInstallations: excluded)
            } catch {
                return
            }
            guard let job else { return }
            guard !stopping else {
                try? await store.release(jobID: job.id, leaseOwner: owner, scheduledAt: now())
                return
            }
            activeByInstallation[job.installationID, default: 0] += 1
            let task = Task { await self.process(job, leaseOwner: owner) }
            tasks[owner] = task
        }
    }

    private func process(_ job: StoredJob, leaseOwner: String) async {
        await metrics.jobStarted()
        do {
            try Task.checkCancellation()
            let result = try await orchestrator.execute(
                job.job, knownCheckRunID: job.checkRunID,
                checkIdentified: { [store] checkID in
                    try await store.saveCheckRunID(
                        jobID: job.id, leaseOwner: leaseOwner, checkRunID: checkID)
                })
            if result.superseded {
                try? await store.fail(jobID: job.id, leaseOwner: leaseOwner,
                                      category: "superseded", now: now(), retention: retention)
                await metrics.jobSuperseded()
            } else {
                try await store.complete(jobID: job.id, leaseOwner: leaseOwner,
                                         now: now(), retention: retention)
                await metrics.jobCompleted(
                    latency: now().timeIntervalSince(job.createdAt),
                    publishedCheckCount: result.publishedCheckCount)
            }
        } catch is CancellationError {
            try? await store.release(jobID: job.id, leaseOwner: leaseOwner, scheduledAt: now())
            await metrics.jobReleased()
        } catch GitHubAPIError.retryable(let directive) {
            if let schedule = retryPolicy.nextSchedule(for: job, directive: directive, now: now()) {
                try? await store.reschedule(jobID: job.id, leaseOwner: leaseOwner,
                                            category: directive.category.rawValue,
                                            scheduledAt: schedule)
                let limited: Set<GitHubRetryCategory> = [
                    .tooManyRequests, .primaryRateLimit, .secondaryRateLimit,
                ]
                await metrics.jobRetried(rateLimited: limited.contains(directive.category))
            } else {
                try? await store.fail(jobID: job.id, leaseOwner: leaseOwner,
                                      category: "retry_budget_exhausted", now: now(), retention: retention)
                await metrics.jobFailed()
            }
        } catch let diagnostic as SafeDiagnostic where diagnostic.code == "job_store.lease_lost" {
            await metrics.jobSuperseded()
        } catch {
            try? await store.fail(jobID: job.id, leaseOwner: leaseOwner,
                                  category: Self.category(error), now: now(), retention: retention)
            await metrics.jobFailed()
        }
        finished(leaseOwner: leaseOwner, installationID: job.installationID)
    }

    private func finished(leaseOwner: String, installationID: Int64) {
        tasks[leaseOwner] = nil
        let count = max(0, (activeByInstallation[installationID] ?? 1) - 1)
        activeByInstallation[installationID] = count == 0 ? nil : count
    }

    private static func category(_ error: Error) -> String {
        switch error {
        case GitHubAPIError.unauthorized: "github_unauthorized"
        case GitHubAPIError.forbidden: "github_forbidden"
        case GitHubAPIError.notFound: "github_not_found"
        case GitHubAPIError.responseTooLarge: "github_response_too_large"
        case is GitHubAPIError: "github_permanent_failure"
        default: "processing_failed"
        }
    }
}
