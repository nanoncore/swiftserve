import Foundation
import SwiftServeCapability
import SwiftServeCore
import SwiftServeReceipt

public actor GitHubCheckOrchestrator {
    public static let outputByteLimit = 65_535

    private let api: any GitHubAPI
    private let gate: ReceiptGateThreshold
    private let capabilityDataset: CapabilityDataset
    private let generatedAt: @Sendable () -> String

    public init(api: any GitHubAPI, gate: ReceiptGateThreshold = .block,
                capabilityDataset: CapabilityDataset,
                generatedAt: @escaping @Sendable () -> String = GitHubCheckOrchestrator.timestamp) {
        self.api = api
        self.gate = gate
        self.capabilityDataset = capabilityDataset
        self.generatedAt = generatedAt
    }

    public func process(_ job: WebhookJob) async {
        switch job {
        case .pullRequest(let event):
            await process(event)
        case .basePush(let event):
            await processBasePush(event)
        }
    }

    public func process(_ event: PullRequestEvent) async {
        do {
            let lockfiles = try await changedLockfiles(for: event)
            switch lockfiles.count {
            case 0:
                try await publish(
                    event: event, conclusion: .skipped, title: "No Package.resolved changed",
                    summary: "SwiftServe skipped this pull request because it does not change a `Package.resolved` file.")
            case 1:
                try await analyze(event: event, change: lockfiles[0])
            default:
                let paths = Set(lockfiles.flatMap(\.displayPaths)).sorted()
                let list = paths.map { "- `\($0)`" }.joined(separator: "\n")
                try await publish(
                    event: event, conclusion: .actionRequired,
                    title: "Multiple Package.resolved files need review",
                    summary: "SwiftServe found multiple changed lockfiles. Multi-lockfile aggregation arrives in a later slice.\n\n\(list)")
            }
        } catch {
            // Error text is deliberately fixed: transport failures, policy
            // bytes, lockfiles, tokens, and request bodies never enter output.
            try? await publish(
                event: event, conclusion: .failure, title: "Upgrade Receipt could not be produced",
                summary: "SwiftServe failed closed because a required immutable input was missing, malformed, or untrustworthy.")
        }
    }

    private func processBasePush(_ event: RepositoryPushEvent) async {
        var pageNumber = 1
        do {
            while true {
                guard pageNumber <= 100 else { throw GitHubAPIError.malformedResponse }
                let page = try await api.pullRequests(
                    repository: event.repository, baseRef: event.branch,
                    installationID: event.installationID, page: pageNumber, perPage: 100)
                for pullRequest in page.values {
                    await process(pullRequest)
                }
                guard page.hasNext else { return }
                pageNumber += 1
            }
        } catch {
            // A later webhook will retry. Never publish against a PR state that
            // could not be fetched from GitHub.
        }
    }

    private struct LockfileChange: Sendable {
        let basePath: String?
        let headPath: String?
        let displayPaths: [String]
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
                    return newIsLockfile
                        ? .init(basePath: nil, headPath: file.filename, displayPaths: [file.filename])
                        : nil
                case "removed":
                    return newIsLockfile
                        ? .init(basePath: file.filename, headPath: nil, displayPaths: [file.filename])
                        : nil
                case "renamed":
                    guard newIsLockfile || previousIsLockfile else { return nil }
                    let paths = [file.previousFilename, Optional(file.filename)].compactMap { $0 }
                    return .init(
                        basePath: previousIsLockfile ? file.previousFilename : nil,
                        headPath: newIsLockfile ? file.filename : nil,
                        displayPaths: paths)
                default:
                    return newIsLockfile
                        ? .init(basePath: file.filename, headPath: file.filename,
                                displayPaths: [file.filename])
                        : nil
                }
            }
            guard page.hasNext else { return changes }
            pageNumber += 1
        }
    }

    private static func isLockfile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "Package.resolved"
    }

    private func analyze(event: PullRequestEvent, change: LockfileChange) async throws {
        async let basePins = pins(repository: event.repository, path: change.basePath,
                                  ref: event.baseSHA, installationID: event.installationID)
        async let headPins = pins(repository: event.repository, path: change.headPath,
                                  ref: event.headSHA, installationID: event.installationID)
        let policy: ReceiptPolicy
        let policySource: String
        do {
            let data = try await api.content(repository: event.repository, path: ".swiftserve.json",
                                             ref: event.baseSHA, installationID: event.installationID)
            policy = try ReceiptPolicy.decode(from: data)
            policySource = ".swiftserve.json@base"
        } catch GitHubAPIError.notFound {
            policy = .default
            policySource = "default"
        }

        let receipt = ReceiptEngine.build(
            base: try await basePins, head: try await headPins, generatedAt: generatedAt(),
            context: .init(policy: policy, policySource: policySource,
                           capabilityDataset: capabilityDataset))
        let markdown = UpgradeReceiptMarkdownRenderer.render(receipt)
        try await publish(
            event: event, conclusion: Self.conclusion(for: receipt.verdict, gate: gate),
            title: "Upgrade Receipt — \(receipt.verdict.rawValue.uppercased())", summary: markdown)
    }

    private func pins(repository: RepositoryCoordinates, path: String?, ref: String,
                      installationID: Int64) async throws -> [Pin] {
        guard let path else { return [] }
        let data = try await api.content(
            repository: repository, path: path, ref: ref, installationID: installationID)
        return try PackageResolvedParser().parse(data)
    }

    private func publish(event: PullRequestEvent, conclusion: CheckConclusion,
                         title: String, summary: String) async throws {
        let current = try await api.currentPullRequest(for: event)
        guard current.baseRef == event.baseRef,
              current.baseSHA == event.baseSHA,
              current.headSHA == event.headSHA else {
            return // A webhook for the current immutable inputs owns the result.
        }
        let publication = CheckPublication(
            headSHA: event.headSHA, externalID: event.externalID, conclusion: conclusion,
            title: title, summary: Self.boundedMarkdown(summary))
        if let id = try await api.checkRunID(
            repository: event.repository, headSHA: event.headSHA, externalID: event.externalID,
            installationID: event.installationID) {
            try await api.updateCheck(repository: event.repository, id: id, publication: publication,
                                      installationID: event.installationID)
        } else {
            try await api.createCheck(repository: event.repository, publication: publication,
                                      installationID: event.installationID)
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

    public static func boundedMarkdown(_ markdown: String,
                                       limit: Int = outputByteLimit) -> String {
        guard markdown.utf8.count > limit else { return markdown }
        let marker = "\n\n_Receipt truncated to fit GitHub Check output limits._"
        let budget = max(0, limit - marker.utf8.count)
        var result = ""
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = result.isEmpty ? String(line) : result + "\n" + line
            guard candidate.utf8.count <= budget else { break }
            result = candidate
        }
        return result + marker
    }

    public static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
