import Foundation
import SwiftServeCapability
import SwiftServeCore
import SwiftServeReceipt

public struct CheckProcessResult: Sendable, Equatable {
    public let checkRunID: Int64?
    public let superseded: Bool
    public let publishedCheckCount: Int

    public init(checkRunID: Int64?, superseded: Bool, publishedCheckCount: Int) {
        self.checkRunID = checkRunID
        self.superseded = superseded
        self.publishedCheckCount = publishedCheckCount
    }
}

public actor GitHubCheckOrchestrator {
    public static let outputByteLimit = 65_535

    private let api: any GitHubAPI
    private let gate: ReceiptGateThreshold
    private let capabilityDataset: CapabilityDataset
    private let generatedAt: @Sendable () -> String
    private let lockfileLimit: Int
    private let policyLimit: Int

    public init(api: any GitHubAPI, gate: ReceiptGateThreshold = .block,
                capabilityDataset: CapabilityDataset,
                lockfileLimit: Int = 5 << 20,
                policyLimit: Int = 256 << 10,
                generatedAt: @escaping @Sendable () -> String = GitHubCheckOrchestrator.timestamp) {
        self.api = api
        self.gate = gate
        self.capabilityDataset = capabilityDataset
        self.lockfileLimit = lockfileLimit
        self.policyLimit = policyLimit
        self.generatedAt = generatedAt
    }

    /// Compatibility entry point used by focused orchestration tests and the
    /// original spike target. Durable workers call `execute` so retryable API
    /// failures remain visible to the scheduler.
    public func process(_ job: WebhookJob) async {
        _ = try? await execute(job)
    }

    public func process(_ event: PullRequestEvent) async {
        _ = try? await execute(.pullRequest(event))
    }

    public func execute(
        _ job: WebhookJob,
        knownCheckRunID: Int64? = nil,
        checkIdentified: (@Sendable (Int64) async throws -> Void)? = nil
    ) async throws -> CheckProcessResult {
        switch job {
        case .pullRequest(let event):
            return try await execute(event, knownCheckRunID: knownCheckRunID,
                                     checkIdentified: checkIdentified)
        case .basePush(let event):
            let count = try await processBasePush(event)
            return .init(checkRunID: nil, superseded: false, publishedCheckCount: count)
        }
    }

    private func execute(
        _ event: PullRequestEvent,
        knownCheckRunID: Int64?,
        checkIdentified: (@Sendable (Int64) async throws -> Void)?
    ) async throws -> CheckProcessResult {
        guard try await isCurrent(event) else {
            return .init(checkRunID: knownCheckRunID, superseded: true, publishedCheckCount: 0)
        }

        let progress = CheckPublication(
            headSHA: event.headSHA, externalID: event.externalID,
            inProgressTitle: "Analyzing Package.resolved changes")
        let checkID: Int64
        if let knownCheckRunID {
            checkID = knownCheckRunID
            try await api.updateCheck(repository: event.repository, id: checkID,
                                      publication: progress, installationID: event.installationID)
        } else if let existing = try await api.checkRunID(
            repository: event.repository, headSHA: event.headSHA, externalID: event.externalID,
            installationID: event.installationID) {
            checkID = existing
            try await api.updateCheck(repository: event.repository, id: existing,
                                      publication: progress, installationID: event.installationID)
        } else {
            checkID = try await api.createCheck(repository: event.repository, publication: progress,
                                                installationID: event.installationID)
        }
        try await checkIdentified?(checkID)

        let final: CheckPublication
        do {
            final = try await finalPublication(for: event)
        } catch let error as GitHubAPIError {
            if case .retryable = error { throw error }
            final = failurePublication(
                event: event, title: "Upgrade Receipt could not be produced",
                summary: "SwiftServe failed closed because a required immutable GitHub input was missing, malformed, or untrustworthy.")
        } catch {
            final = failurePublication(
                event: event, title: "Upgrade Receipt could not be produced",
                summary: "SwiftServe failed closed because a required immutable input was missing, malformed, or untrustworthy.")
        }

        guard try await isCurrent(event) else {
            return .init(checkRunID: checkID, superseded: true, publishedCheckCount: 0)
        }
        try await api.updateCheck(repository: event.repository, id: checkID,
                                  publication: final, installationID: event.installationID)
        return .init(checkRunID: checkID, superseded: false, publishedCheckCount: 1)
    }

    private func processBasePush(_ event: RepositoryPushEvent) async throws -> Int {
        var pageNumber = 1
        var published = 0
        while true {
            guard pageNumber <= 100 else { throw GitHubAPIError.malformedResponse }
            let page = try await api.pullRequests(
                repository: event.repository, baseRef: event.branch,
                installationID: event.installationID, page: pageNumber, perPage: 100)
            for pullRequest in page.values {
                published += try await execute(
                    pullRequest, knownCheckRunID: nil,
                    checkIdentified: nil).publishedCheckCount
            }
            guard page.hasNext else { return published }
            pageNumber += 1
        }
    }

    struct LockfileChange: Sendable, Equatable {
        let basePath: String?
        let headPath: String?

        var sortPath: String { headPath ?? basePath ?? "" }
        var displayPath: String {
            if let basePath, let headPath, basePath != headPath { return "\(basePath) → \(headPath)" }
            return headPath ?? basePath ?? "Package.resolved"
        }
    }

    private func changedLockfiles(for event: PullRequestEvent) async throws -> [LockfileChange] {
        var pageNumber = 1
        var changes: [LockfileChange] = []
        while true {
            guard pageNumber <= 100 else { throw GitHubAPIError.malformedResponse }
            let page = try await api.changedFiles(for: event, page: pageNumber, perPage: 100)
            changes += page.values.compactMap { file in
                let newIsLockfile = Self.isLockfile(file.filename)
                let previousIsLockfile = file.previousFilename.map(Self.isLockfile) ?? false
                switch file.status {
                case "added", "copied":
                    return newIsLockfile ? .init(basePath: nil, headPath: file.filename) : nil
                case "removed":
                    return newIsLockfile ? .init(basePath: file.filename, headPath: nil) : nil
                case "renamed":
                    guard newIsLockfile || previousIsLockfile else { return nil }
                    return .init(basePath: previousIsLockfile ? file.previousFilename : nil,
                                 headPath: newIsLockfile ? file.filename : nil)
                default:
                    return newIsLockfile
                        ? .init(basePath: file.filename, headPath: file.filename) : nil
                }
            }
            guard page.hasNext else {
                return changes.sorted {
                    ($0.sortPath, $0.basePath ?? "", $0.headPath ?? "") <
                    ($1.sortPath, $1.basePath ?? "", $1.headPath ?? "")
                }
            }
            pageNumber += 1
        }
    }

    private static func isLockfile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "Package.resolved"
    }

    private struct LockfileOutcome {
        let change: LockfileChange
        let verdict: ReceiptVerdict?
        let markdown: String?
        let errorCode: String?

        var severity: Int {
            guard let verdict else { return 3 }
            switch verdict { case .pass: return 0; case .review: return 1; case .block: return 2 }
        }

        var label: String {
            if errorCode != nil { return "BLOCK (input error)" }
            return verdict?.rawValue.uppercased() ?? "BLOCK"
        }
    }

    private func finalPublication(for event: PullRequestEvent) async throws -> CheckPublication {
        let changes = try await changedLockfiles(for: event)
        guard !changes.isEmpty else {
            return CheckPublication(
                headSHA: event.headSHA, externalID: event.externalID, conclusion: .skipped,
                title: "No Package.resolved changed",
                summary: "SwiftServe skipped this pull request because it does not change a `Package.resolved` file.")
        }

        let policy: ReceiptPolicy
        let policySource: String
        do {
            let data = try await api.content(repository: event.repository, path: ".swiftserve.json",
                                             ref: event.baseSHA, installationID: event.installationID)
            guard data.count <= policyLimit else {
                return policyFailure(event: event, changes: changes, code: "policy_too_large")
            }
            do {
                policy = try ReceiptPolicy.decode(from: data)
                policySource = ".swiftserve.json@base"
            } catch {
                return policyFailure(event: event, changes: changes, code: "policy_malformed")
            }
        } catch GitHubAPIError.notFound {
            policy = .default
            policySource = "default"
        }

        var outcomes: [LockfileOutcome] = []
        for change in changes {
            outcomes.append(try await analyze(
                event: event, change: change, policy: policy, policySource: policySource))
        }

        let worst = outcomes.map(\.severity).max() ?? 0
        let aggregateVerdict: ReceiptVerdict = worst >= 2 ? .block : (worst == 1 ? .review : .pass)
        let conclusion = Self.conclusion(for: aggregateVerdict, gate: gate)
        let summary = Self.aggregateMarkdown(
            verdict: aggregateVerdict, conclusion: conclusion, outcomes: outcomes,
            limit: Self.outputByteLimit)
        return CheckPublication(
            headSHA: event.headSHA, externalID: event.externalID, conclusion: conclusion,
            title: "Upgrade Receipt — \(aggregateVerdict.rawValue.uppercased()) (\(changes.count) lockfile\(changes.count == 1 ? "" : "s"))",
            summary: summary)
    }

    private func analyze(event: PullRequestEvent, change: LockfileChange,
                         policy: ReceiptPolicy, policySource: String) async throws -> LockfileOutcome {
        do {
            async let basePins = pins(repository: event.repository, path: change.basePath,
                                      ref: event.baseSHA, installationID: event.installationID)
            async let headPins = pins(repository: event.repository, path: change.headPath,
                                      ref: event.headSHA, installationID: event.installationID)
            let receipt = ReceiptEngine.build(
                base: try await basePins, head: try await headPins, generatedAt: generatedAt(),
                context: .init(policy: policy, policySource: policySource,
                               capabilityDataset: capabilityDataset))
            return .init(change: change, verdict: receipt.verdict,
                         markdown: UpgradeReceiptMarkdownRenderer.render(receipt), errorCode: nil)
        } catch let error as GitHubAPIError {
            if case .retryable = error { throw error }
            return .init(change: change, verdict: nil, markdown: nil,
                         errorCode: Self.inputErrorCode(error))
        } catch {
            return .init(change: change, verdict: nil, markdown: nil,
                         errorCode: "lockfile_malformed")
        }
    }

    private func pins(repository: RepositoryCoordinates, path: String?, ref: String,
                      installationID: Int64) async throws -> [Pin] {
        guard let path else { return [] }
        let data = try await api.content(
            repository: repository, path: path, ref: ref, installationID: installationID)
        guard data.count <= lockfileLimit else { throw GitHubAPIError.responseTooLarge }
        return try PackageResolvedParser().parse(data)
    }

    private func policyFailure(event: PullRequestEvent, changes: [LockfileChange],
                               code: String) -> CheckPublication {
        let rows = changes.map {
            "| \(Self.markdownTableCode($0.displayPath)) | BLOCK (policy error) |"
        }.joined(separator: "\n")
        let summary = """
        # SwiftServe Upgrade Receipt — BLOCK

        **Aggregate gate:** `failure`

        | Lockfile | Verdict |
        |---|---|
        \(rows)

        ## Required input error

        `\(code)` at `.swiftserve.json`. Contents were not retained or exposed.
        """
        return failurePublication(event: event, title: "Upgrade Receipt — BLOCK (policy input)",
                                  summary: Self.boundedMarkdown(summary))
    }

    private func failurePublication(event: PullRequestEvent, title: String,
                                    summary: String) -> CheckPublication {
        CheckPublication(headSHA: event.headSHA, externalID: event.externalID,
                         conclusion: .failure, title: title,
                         summary: Self.boundedMarkdown(summary))
    }

    private func isCurrent(_ event: PullRequestEvent) async throws -> Bool {
        let current = try await api.currentPullRequest(for: event)
        return current.baseRef == event.baseRef && current.baseSHA == event.baseSHA &&
            current.headSHA == event.headSHA
    }

    private static func inputErrorCode(_ error: GitHubAPIError) -> String {
        switch error {
        case .notFound: "required_file_missing"
        case .responseTooLarge: "lockfile_too_large"
        case .malformedResponse: "github_content_untrustworthy"
        case .unauthorized: "github_authorization_failed"
        case .forbidden: "github_permission_failed"
        case .invalidRequest: "path_or_revision_invalid"
        default: "github_input_failed"
        }
    }

    public static func conclusion(for verdict: ReceiptVerdict,
                                  gate: ReceiptGateThreshold) -> CheckConclusion {
        switch verdict {
        case .pass: .success
        case .review: gate == .block ? .neutral : .failure
        case .block: .failure
        }
    }

    private static func aggregateMarkdown(verdict: ReceiptVerdict, conclusion: CheckConclusion,
                                          outcomes: [LockfileOutcome], limit: Int) -> String {
        let ordered = outcomes.sorted { $0.change.sortPath < $1.change.sortPath }
        let rows = ordered.map {
            "| \(markdownTableCode($0.change.displayPath)) | \($0.label) |"
        }.joined(separator: "\n")
        var header = """
        # SwiftServe Upgrade Receipt — \(verdict.rawValue.uppercased())

        **Aggregate gate:** `\(conclusion.rawValue)`
        **Per-lockfile boundary:** packages are not deduplicated across lockfiles.

        | Lockfile | Verdict |
        |---|---|
        \(rows)
        """
        if header.utf8.count > limit / 2 {
            header = boundedMarkdown(header, limit: limit / 2)
        }
        let sections = outcomes.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.change.sortPath < $1.change.sortPath
        }.map { outcome -> String in
            let heading = "## \(markdownCode(outcome.change.displayPath))"
            if let markdown = outcome.markdown { return heading + "\n\n" + markdown }
            return heading + "\n\n`\(outcome.errorCode ?? "lockfile_untrustworthy")`. " +
                "This lockfile failed closed; its contents were not retained or exposed."
        }
        var result = header
        var omitted = 0
        for section in sections {
            let candidate = result + "\n\n" + section
            let markerBudget = "\n\n_9999 lockfile sections omitted to fit GitHub Check output limits._".utf8.count
            if candidate.utf8.count + markerBudget <= limit {
                result = candidate
            } else {
                omitted += 1
            }
        }
        if omitted > 0 {
            let marker = "\n\n_\(omitted) lockfile section\(omitted == 1 ? "" : "s") omitted to fit GitHub Check output limits._"
            if result.utf8.count + marker.utf8.count <= limit { result += marker }
        }
        return result
    }

    public static func boundedMarkdown(_ markdown: String,
                                       limit: Int = outputByteLimit) -> String {
        guard markdown.utf8.count > limit else { return markdown }
        let marker = "\n\n_Output truncated at a safe line boundary for GitHub Check limits._"
        let budget = max(0, limit - marker.utf8.count)
        var result = ""
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = result.isEmpty ? String(line) : result + "\n" + line
            guard candidate.utf8.count <= budget else { break }
            result = candidate
        }
        return result + marker
    }

    static func markdownCode(_ untrusted: String) -> String {
        let visible = visiblePath(untrusted)
        var longest = 0
        var current = 0
        for character in visible {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(1, longest + 1))
        return fence + " " + visible + " " + fence
    }

    static func markdownTableCode(_ untrusted: String) -> String {
        markdownCode(untrusted).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func visiblePath(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x00..<0x20, 0x7F: result += "\\u{" + String(scalar.value, radix: 16) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
