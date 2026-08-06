import Foundation
import GRDB

public enum StoredJobState: String, Codable, Sendable, Equatable {
    case pending
    case running
    case completed
    case failed
    case superseded
}

public struct StoredJob: Sendable, Equatable {
    public let id: String
    public let deliveryID: String
    public let job: WebhookJob
    public let checkRunID: Int64?
    public let attemptCount: Int
    public let state: StoredJobState
    public let createdAt: Date
    public let scheduledAt: Date
    public let leaseExpiresAt: Date?

    public init(id: String, deliveryID: String, job: WebhookJob,
                checkRunID: Int64?, attemptCount: Int, state: StoredJobState,
                createdAt: Date, scheduledAt: Date, leaseExpiresAt: Date?) {
        self.id = id
        self.deliveryID = deliveryID
        self.job = job
        self.checkRunID = checkRunID
        self.attemptCount = attemptCount
        self.state = state
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt
        self.leaseExpiresAt = leaseExpiresAt
    }

    public var installationID: Int64 {
        switch job {
        case .pullRequest(let event): event.installationID
        case .basePush(let event): event.installationID
        }
    }
}

public enum JobEnqueueResult: Sendable, Equatable {
    case inserted
    case revived
    case duplicate
}

public protocol JobStore: Sendable {
    func enqueue(deliveryID: String, job: WebhookJob, now: Date,
                 retention: TimeInterval) async throws -> JobEnqueueResult
    func claim(leaseOwner: String, now: Date, leaseDuration: TimeInterval,
               excludingInstallations: Set<Int64>) async throws -> StoredJob?
    func renew(jobID: String, leaseOwner: String, now: Date,
               leaseDuration: TimeInterval) async throws
    func saveCheckRunID(jobID: String, leaseOwner: String, checkRunID: Int64) async throws
    func complete(jobID: String, leaseOwner: String, now: Date,
                  retention: TimeInterval) async throws
    func fail(jobID: String, leaseOwner: String, category: String, now: Date,
              retention: TimeInterval) async throws
    func reschedule(jobID: String, leaseOwner: String, category: String,
                    scheduledAt: Date) async throws
    func release(jobID: String, leaseOwner: String, scheduledAt: Date) async throws
    func prune(now: Date) async throws -> Int
    func queueDepth() async throws -> Int
    func isReady() async -> Bool
}

public actor SQLiteJobStore: JobStore {
    public static let migrationNames = ["v1_create_jobs"]
    private let database: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(Self.migrationNames[0]) { db in
            try db.create(table: "github_jobs") { table in
                table.column("id", .text).primaryKey()
                table.column("delivery_id", .text).notNull().unique()
                table.column("idempotency_key", .text).notNull().unique()
                table.column("kind", .text).notNull()
                table.column("installation_id", .integer).notNull()
                table.column("repository_id", .integer).notNull()
                table.column("repository_owner", .text).notNull()
                table.column("repository_name", .text).notNull()
                table.column("pull_request_number", .integer)
                table.column("base_ref", .text).notNull()
                table.column("base_sha", .text).notNull()
                table.column("head_sha", .text).notNull()
                table.column("external_id", .text)
                table.column("check_run_id", .integer)
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("state", .text).notNull()
                table.column("lease_owner", .text)
                table.column("lease_expires_at", .double)
                table.column("scheduled_at", .double).notNull()
                table.column("created_at", .double).notNull()
                table.column("completed_at", .double)
                table.column("expires_at", .double).notNull()
                table.column("terminal_error_category", .text)
            }
            try db.create(index: "github_jobs_claim", on: "github_jobs",
                          columns: ["state", "scheduled_at", "created_at"])
            try db.create(index: "github_jobs_pr", on: "github_jobs",
                          columns: ["repository_id", "pull_request_number", "state"])
            try db.create(index: "github_jobs_expiry", on: "github_jobs", columns: ["expires_at"])
        }
        try migrator.migrate(database)
    }

    public func enqueue(deliveryID: String, job: WebhookJob, now: Date,
                        retention: TimeInterval) throws -> JobEnqueueResult {
        let fields = Self.fields(job)
        return try database.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT id, delivery_id, idempotency_key, state, repository_id,
                       pull_request_number, created_at
                FROM github_jobs
                WHERE delivery_id = ? OR idempotency_key = ?
                ORDER BY CASE WHEN delivery_id = ? THEN 0 ELSE 1 END
                LIMIT 1
                """,
                arguments: [deliveryID, job.stableID, deliveryID]) {
                let existingKey: String = existing["idempotency_key"]
                let existingState: String = existing["state"]
                guard existingKey == job.stableID, existingState == StoredJobState.failed.rawValue else {
                    return .duplicate
                }
                if let number: Int = existing["pull_request_number"] {
                    let repositoryID: Int64 = existing["repository_id"]
                    let createdAt: Double = existing["created_at"]
                    let newerExists = try Bool.fetchOne(
                        db,
                        sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM github_jobs
                            WHERE repository_id = ? AND pull_request_number = ?
                              AND created_at > ? AND idempotency_key <> ?
                              AND state IN ('pending', 'running', 'completed')
                        )
                        """,
                        arguments: [repositoryID, number, createdAt, job.stableID]) == true
                    if newerExists { return .duplicate }
                }
                let existingID: String = existing["id"]
                try db.execute(
                    sql: """
                    UPDATE github_jobs
                    SET delivery_id = ?, state = 'pending', attempt_count = 0,
                        scheduled_at = ?, created_at = ?, completed_at = NULL,
                        expires_at = ?, lease_owner = NULL, lease_expires_at = NULL,
                        terminal_error_category = NULL
                    WHERE id = ? AND state = 'failed' AND idempotency_key = ?
                    """,
                    arguments: [deliveryID, now.timeIntervalSince1970,
                                now.timeIntervalSince1970,
                                Date.distantFuture.timeIntervalSince1970,
                                existingID, job.stableID])
                guard db.changesCount == 1 else { return .duplicate }
                return .revived
            }
            if let number = fields.pullRequestNumber {
                try db.execute(
                    sql: """
                    UPDATE github_jobs
                    SET state = 'superseded', completed_at = ?, expires_at = ?,
                        lease_owner = NULL, lease_expires_at = NULL,
                        terminal_error_category = 'superseded'
                    WHERE repository_id = ? AND pull_request_number = ?
                      AND state IN ('pending', 'running') AND idempotency_key <> ?
                    """,
                    arguments: [now.timeIntervalSince1970,
                                now.addingTimeInterval(retention).timeIntervalSince1970,
                                fields.repository.id, number, job.stableID])
            }
            try db.execute(
                sql: """
                INSERT INTO github_jobs
                (id, delivery_id, idempotency_key, kind, installation_id,
                 repository_id, repository_owner, repository_name,
                 pull_request_number, base_ref, base_sha, head_sha, external_id,
                 attempt_count, state, scheduled_at, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'pending', ?, ?, ?)
                """,
                arguments: [deliveryID, deliveryID, job.stableID, fields.kind,
                            fields.installationID, fields.repository.id,
                            fields.repository.owner, fields.repository.name,
                            fields.pullRequestNumber, fields.baseRef, fields.baseSHA,
                            fields.headSHA, fields.externalID,
                            now.timeIntervalSince1970, now.timeIntervalSince1970,
                            Date.distantFuture.timeIntervalSince1970])
            return .inserted
        }
    }

    public func claim(leaseOwner: String, now: Date, leaseDuration: TimeInterval,
                      excludingInstallations: Set<Int64>) throws -> StoredJob? {
        try database.write { db in
            let timestamp = now.timeIntervalSince1970
            try db.execute(
                sql: """
                UPDATE github_jobs SET state = 'pending', lease_owner = NULL, lease_expires_at = NULL
                WHERE state = 'running' AND lease_expires_at <= ?
                """,
                arguments: [timestamp])
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM github_jobs
                WHERE state = 'pending' AND scheduled_at <= ? AND expires_at > ?
                ORDER BY scheduled_at ASC, created_at ASC, id ASC LIMIT 256
                """,
                arguments: [timestamp, timestamp])
            guard let row = rows.first(where: {
                let installation: Int64 = $0["installation_id"]
                return !excludingInstallations.contains(installation)
            }) else { return nil }
            let id: String = row["id"]
            try db.execute(
                sql: """
                UPDATE github_jobs
                SET state = 'running', lease_owner = ?, lease_expires_at = ?, attempt_count = attempt_count + 1
                WHERE id = ? AND state = 'pending'
                """,
                arguments: [leaseOwner, now.addingTimeInterval(leaseDuration).timeIntervalSince1970, id])
            guard db.changesCount == 1,
                  let claimed = try Row.fetchOne(db, sql: "SELECT * FROM github_jobs WHERE id = ?", arguments: [id])
            else { return nil }
            return try Self.decode(claimed)
        }
    }

    public func saveCheckRunID(jobID: String, leaseOwner: String, checkRunID: Int64) throws {
        try mutateLease(jobID: jobID, leaseOwner: leaseOwner,
                        sql: "UPDATE github_jobs SET check_run_id = ? WHERE id = ? AND state = 'running' AND lease_owner = ?",
                        arguments: [checkRunID, jobID, leaseOwner])
    }

    public func renew(jobID: String, leaseOwner: String, now: Date,
                      leaseDuration: TimeInterval) throws {
        try mutateLease(
            jobID: jobID, leaseOwner: leaseOwner,
            sql: """
            UPDATE github_jobs SET lease_expires_at = ?
            WHERE id = ? AND state = 'running' AND lease_owner = ?
              AND lease_expires_at > ?
            """,
            arguments: [now.addingTimeInterval(leaseDuration).timeIntervalSince1970,
                        jobID, leaseOwner, now.timeIntervalSince1970])
    }

    public func complete(jobID: String, leaseOwner: String, now: Date,
                         retention: TimeInterval) throws {
        try terminal(jobID: jobID, leaseOwner: leaseOwner, state: .completed,
                     category: nil, now: now, retention: retention)
    }

    public func fail(jobID: String, leaseOwner: String, category: String, now: Date,
                     retention: TimeInterval) throws {
        try terminal(jobID: jobID, leaseOwner: leaseOwner, state: .failed,
                     category: category, now: now, retention: retention)
    }

    public func reschedule(jobID: String, leaseOwner: String, category: String,
                           scheduledAt: Date) throws {
        try mutateLease(
            jobID: jobID, leaseOwner: leaseOwner,
            sql: """
            UPDATE github_jobs SET state = 'pending', scheduled_at = ?, lease_owner = NULL,
                lease_expires_at = NULL, terminal_error_category = ?
            WHERE id = ? AND state = 'running' AND lease_owner = ?
            """,
            arguments: [scheduledAt.timeIntervalSince1970, category, jobID, leaseOwner])
    }

    public func release(jobID: String, leaseOwner: String, scheduledAt: Date) throws {
        try mutateLease(
            jobID: jobID, leaseOwner: leaseOwner,
            sql: """
            UPDATE github_jobs SET state = 'pending', scheduled_at = ?, lease_owner = NULL, lease_expires_at = NULL
            WHERE id = ? AND state = 'running' AND lease_owner = ?
            """,
            arguments: [scheduledAt.timeIntervalSince1970, jobID, leaseOwner])
    }

    public func prune(now: Date) throws -> Int {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM github_jobs WHERE expires_at <= ? AND state IN ('completed', 'failed', 'superseded')",
                arguments: [now.timeIntervalSince1970])
            return db.changesCount
        }
    }

    public func queueDepth() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM github_jobs WHERE state IN ('pending', 'running')") ?? 0
        }
    }

    public func isReady() -> Bool {
        (try? database.read { db in try Int.fetchOne(db, sql: "SELECT 1") == 1 }) == true
    }

    private func terminal(jobID: String, leaseOwner: String, state: StoredJobState,
                          category: String?, now: Date, retention: TimeInterval) throws {
        try mutateLease(
            jobID: jobID, leaseOwner: leaseOwner,
            sql: """
            UPDATE github_jobs SET state = ?, completed_at = ?, expires_at = ?,
                lease_owner = NULL, lease_expires_at = NULL, terminal_error_category = ?
            WHERE id = ? AND state = 'running' AND lease_owner = ?
            """,
            arguments: [state.rawValue, now.timeIntervalSince1970,
                        now.addingTimeInterval(retention).timeIntervalSince1970,
                        category, jobID, leaseOwner])
    }

    private func mutateLease(jobID: String, leaseOwner: String, sql: String,
                             arguments: StatementArguments) throws {
        try database.write { db in
            try db.execute(sql: sql, arguments: arguments)
            guard db.changesCount == 1 else {
                throw SafeDiagnostic(code: "job_store.lease_lost", message: "The durable job lease is no longer owned")
            }
        }
    }

    private struct Fields {
        let kind: String
        let installationID: Int64
        let repository: RepositoryCoordinates
        let pullRequestNumber: Int?
        let baseRef: String
        let baseSHA: String
        let headSHA: String
        let externalID: String?
    }

    private static func fields(_ job: WebhookJob) -> Fields {
        switch job {
        case .pullRequest(let event):
            return .init(kind: "pull_request", installationID: event.installationID,
                         repository: event.repository, pullRequestNumber: event.number,
                         baseRef: event.baseRef, baseSHA: event.baseSHA, headSHA: event.headSHA,
                         externalID: event.externalID)
        case .basePush(let event):
            return .init(kind: "base_push", installationID: event.installationID,
                         repository: event.repository, pullRequestNumber: nil,
                         baseRef: event.branch, baseSHA: event.afterSHA,
                         headSHA: event.afterSHA, externalID: nil)
        }
    }

    private static func decode(_ row: Row) throws -> StoredJob {
        let repository = RepositoryCoordinates(
            id: row["repository_id"], owner: row["repository_owner"], name: row["repository_name"])
        let installationID: Int64 = row["installation_id"]
        let baseRef: String = row["base_ref"]
        let baseSHA: String = row["base_sha"]
        let headSHA: String = row["head_sha"]
        let kind: String = row["kind"]
        let job: WebhookJob
        if kind == "pull_request", let number: Int = row["pull_request_number"] {
            job = .pullRequest(.init(
                action: "durable", installationID: installationID, repository: repository,
                number: number, baseRef: baseRef, baseSHA: baseSHA, headSHA: headSHA))
        } else if kind == "base_push" {
            job = .basePush(.init(installationID: installationID, repository: repository,
                                  branch: baseRef, afterSHA: headSHA))
        } else {
            throw SafeDiagnostic(code: "job_store.corrupt", message: "A durable job row is invalid")
        }
        let rawState: String = row["state"]
        guard let state = StoredJobState(rawValue: rawState) else {
            throw SafeDiagnostic(code: "job_store.corrupt", message: "A durable job state is invalid")
        }
        let lease: Double? = row["lease_expires_at"]
        let created: Double = row["created_at"]
        let scheduled: Double = row["scheduled_at"]
        return StoredJob(
            id: row["id"], deliveryID: row["delivery_id"], job: job,
            checkRunID: row["check_run_id"], attemptCount: row["attempt_count"], state: state,
            createdAt: Date(timeIntervalSince1970: created),
            scheduledAt: Date(timeIntervalSince1970: scheduled),
            leaseExpiresAt: lease.map(Date.init(timeIntervalSince1970:)))
    }
}

public struct DurableRetryPolicy: Sendable {
    public let maxAttempts: Int
    public let maxElapsed: TimeInterval
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    private let jitter: @Sendable () -> Double

    public init(maxAttempts: Int = 6, maxElapsed: TimeInterval = 900,
                baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 60,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.5) }) {
        self.maxAttempts = maxAttempts
        self.maxElapsed = maxElapsed
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitter = jitter
    }

    public func nextSchedule(for job: StoredJob, directive: GitHubRetryDirective,
                             now: Date) -> Date? {
        guard job.attemptCount < maxAttempts,
              now.timeIntervalSince(job.createdAt) < maxElapsed else { return nil }
        let exponent = min(max(0, job.attemptCount - 1), 16)
        let delay = min(maximumDelay, baseDelay * pow(2, Double(exponent))) * jitter()
        let backoff = now.addingTimeInterval(max(0, delay))
        let scheduled = max(backoff, directive.notBefore ?? backoff)
        guard scheduled.timeIntervalSince(job.createdAt) <= maxElapsed else { return nil }
        return scheduled
    }
}
