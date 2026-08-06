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

    public func process(_ event: PullRequestEvent) async {
        do {
            let lockfiles = try await changedLockfiles(for: event)
            switch lockfiles.count {
            case 0:
                try await publish(
                    event: event, conclusion: .skipped, title: "No Package.resolved changed",
                    summary: "SwiftServe skipped this pull request because it does not change a `Package.resolved` file.")
            case 1:
                try await analyze(event: event, path: lockfiles[0])
            default:
                let list = lockfiles.sorted().map { "- `\($0)`" }.joined(separator: "\n")
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

    private func changedLockfiles(for event: PullRequestEvent) async throws -> [String] {
        var pageNumber = 1
        var paths: [String] = []
        while true {
            guard pageNumber <= 100 else { throw GitHubAPIError.malformedResponse }
            let page = try await api.changedFiles(for: event, page: pageNumber, perPage: 100)
            paths += page.values.map(\.filename).filter {
                ($0 as NSString).lastPathComponent == "Package.resolved"
            }
            guard page.hasNext else { return paths }
            pageNumber += 1
        }
    }

    private func analyze(event: PullRequestEvent, path: String) async throws {
        async let baseData = api.content(repository: event.repository, path: path, ref: event.baseSHA,
                                         installationID: event.installationID)
        async let headData = api.content(repository: event.repository, path: path, ref: event.headSHA,
                                         installationID: event.installationID)
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

        let parser = PackageResolvedParser()
        let basePins = try parser.parse(await baseData)
        let headPins = try parser.parse(await headData)
        let receipt = ReceiptEngine.build(
            base: basePins, head: headPins, generatedAt: generatedAt(),
            context: .init(policy: policy, policySource: policySource,
                           capabilityDataset: capabilityDataset))
        let markdown = UpgradeReceiptMarkdownRenderer.render(receipt)
        try await publish(
            event: event, conclusion: Self.conclusion(for: receipt.verdict, gate: gate),
            title: "Upgrade Receipt — \(receipt.verdict.rawValue.uppercased())", summary: markdown)
    }

    private func publish(event: PullRequestEvent, conclusion: CheckConclusion,
                         title: String, summary: String) async throws {
        guard try await api.currentHeadSHA(for: event) == event.headSHA else {
            return // A newer synchronize event owns the visible result.
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
