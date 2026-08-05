import ArgumentParser
import Foundation
import SwiftServeCapability
import SwiftServeCore
import SwiftServeReceipt
import SwiftServeSurface

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two Package.resolved files and produce an Upgrade Receipt."
    )

    @Argument(help: "Base Package.resolved path.")
    var base: String

    @Argument(help: "Head Package.resolved path.")
    var head: String

    @Flag(name: .long, help: "Emit canonical Upgrade Receipt JSON.")
    var json = false

    @Flag(name: .long, help: "Emit Markdown for GitHub Step Summary.")
    var markdown = false

    @Flag(name: .long, help: "Force the terminal card.")
    var card = false

    @Flag(name: .long, help: "Disable GitHub health enrichment even when GITHUB_TOKEN is set.")
    var fileOnly = false

    @Option(name: .long, help: "JSON policy path. Defaults to ./.swiftserve.json when present.")
    var policy: String?

    @Flag(name: .long, help: "Fetch and re-extract changed indexed packages to revalidate known capabilities.")
    var recheckCapabilities = false

    @Option(name: .long, help: "Exit 1 at this verdict or higher: review|block (default: block).")
    var failOn: ReceiptGateThreshold = .block

    func run() async throws {
        guard [json, markdown, card].filter({ $0 }).count <= 1 else {
            try fail("choose only one of --json, --markdown, or --card")
        }

        let basePins: [Pin]
        let headPins: [Pin]
        do {
            basePins = try PackageResolvedParser().parse(read(base))
            headPins = try PackageResolvedParser().parse(read(head))
        } catch let error as PackageResolvedError {
            try fail(error.description)
        } catch {
            try fail("couldn't read lockfiles: \(error.localizedDescription)")
        }

        let loadedPolicy: ReceiptPolicy
        let policySource: String
        do {
            let resolved = resolvedPolicyPath()
            if let resolved {
                loadedPolicy = try ReceiptPolicy.decode(from: Data(contentsOf: URL(fileURLWithPath: resolved)))
                policySource = resolved
            } else {
                loadedPolicy = .default
                policySource = "default"
            }
        } catch let error as ReceiptPolicyError {
            try fail(error.description)
        } catch {
            try fail("couldn't read policy: \(error.localizedDescription)")
        }

        let dataset: CapabilityDataset
        do {
            dataset = try DatasetLoader.load(override: nil)
        } catch let error as ScanError {
            try fail(error.message)
        } catch {
            try fail("couldn't load capability records: \(error.localizedDescription)")
        }

        let changedPins = Self.changedRepositoryPins(base: basePins, head: headPins)
        let enrichment: [String: EnrichmentData]
        let enrichmentSource: String
        let networkUsed: Bool
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        if !fileOnly, let token, !token.isEmpty, !changedPins.isEmpty {
            let raw = await GitHubEnrichment(token: token).enrich(changedPins)
            enrichment = Dictionary(uniqueKeysWithValues: raw.map {
                (RepoIdentity.normalizedPackageIdentity($0.key), $0.value)
            })
            enrichmentSource = "github"
            networkUsed = true
        } else {
            enrichment = [:]
            enrichmentSource = "fileOnly"
            networkUsed = false
        }

        var rechecked: [String: [CapabilityImpact]] = [:]
        var recheckExecuted = false
        var unavailable: [String] = []
        if recheckCapabilities {
            let result = CapabilityReceiptRechecker.recheck(
                base: basePins, head: headPins, dataset: dataset)
            rechecked = result.impacts
            recheckExecuted = result.executed
            unavailable = result.unavailable
        }

        let generatedAt = ProcessInfo.processInfo.environment["SWIFTSERVE_GENERATED_AT"] ?? Analyzer.timestamp()
        let receipt = ReceiptEngine.build(
            base: basePins, head: headPins, generatedAt: generatedAt,
            context: ReceiptBuildContext(
                policy: loadedPolicy, policySource: policySource,
                enrichment: enrichment, enrichmentSource: enrichmentSource,
                networkUsed: networkUsed, capabilityDataset: dataset,
                recheckedCapabilities: rechecked,
                capabilityRecheckRequested: recheckCapabilities,
                capabilityRecheckExecuted: recheckExecuted,
                unavailablePackages: unavailable))

        switch outputMode {
        case .json: print(try DatasetLoader.encodeJSON(receipt))
        case .markdown: print(UpgradeReceiptRenderer.markdown(receipt))
        case .card: print(UpgradeReceiptRenderer.card(receipt))
        }

        let gateFailed: Bool = switch failOn {
        case .review: receipt.verdict == .review || receipt.verdict == .block
        case .block: receipt.verdict == .block
        }
        if gateFailed { throw ExitCode(1) }
    }

    private enum OutputMode: Equatable { case json, markdown, card }

    private var outputMode: OutputMode {
        if markdown { return .markdown }
        if json { return .json }
        if card { return .card }
        return Terminal.isInteractive ? .card : .json
    }

    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func resolvedPolicyPath() -> String? {
        if let policy { return policy }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".swiftserve.json").path
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    private func fail(_ message: String) throws -> Never {
        let line: String
        if wantsJSONErrors,
           let data = try? JSONEncoder().encode(["error": message]),
           let encoded = String(data: data, encoding: .utf8) {
            line = encoded
        } else {
            line = "Error: \(message)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        throw ExitCode(2)
    }

    private var wantsJSONErrors: Bool {
        json || (!markdown && !card && !Terminal.isInteractive)
    }

    static func changedRepositoryPins(base: [Pin], head: [Pin]) -> [Pin] {
        let old = Dictionary(grouping: base, by: { RepoIdentity.normalizedPackageIdentity($0.identity) })
        let new = Dictionary(grouping: head, by: { RepoIdentity.normalizedPackageIdentity($0.identity) })
        var byRepository: [String: Pin] = [:]
        for identity in Set(old.keys).union(new.keys) {
            let before = old[identity] ?? []
            let after = new[identity] ?? []
            guard before != after, let pin = after.first ?? before.first,
                  pin.kind == .remoteSourceControl else { continue }
            byRepository[RepoIdentity.canonicalURL(pin.location)] = pin
        }
        return byRepository.keys.sorted().compactMap { byRepository[$0] }
    }
}

enum ReceiptGateThreshold: String, ExpressibleByArgument {
    case review
    case block
}

enum UpgradeReceiptRenderer {
    static func card(_ receipt: UpgradeReceipt) -> String {
        let icon = switch receipt.verdict { case .pass: "✓"; case .review: "~"; case .block: "✗" }
        let title = "🍦 Upgrade Receipt — \(receipt.verdict.rawValue.uppercased())"
        var lines = [Style.bold(title), "   \(icon) \(receipt.headline)"]
        lines.append(Style.dim("   \(receipt.base.packageCount) → \(receipt.head.packageCount) packages · \(receipt.counts.total) changes"))
        for change in receipt.changes {
            let marker = switch change.severity { case .info: "+"; case .review: "~"; case .block: "!" }
            let old = pinLabel(change.oldPin)
            let new = pinLabel(change.newPin)
            lines.append("   \(marker) \(change.identity)  \(old) → \(new)  [\(change.classification.rawValue)]")
            for finding in change.findings where finding.severity >= .review {
                lines.append(Style.dim("      \(finding.code.rawValue): \(finding.message)"))
            }
        }
        lines.append(Style.dim("   pass means configured policy passed; compile and test before shipping."))
        return lines.joined(separator: "\n")
    }

    static func markdown(_ receipt: UpgradeReceipt) -> String {
        var lines = [
            "## 🍦 Upgrade Receipt — \(receipt.verdict.rawValue.uppercased())",
            "",
            receipt.headline,
            "",
            "| Package | Before | After | Classification | Severity |",
            "|---|---:|---:|---|---|",
        ]
        if receipt.changes.isEmpty {
            lines.append("| _No dependency changes_ | — | — | — | info |")
        } else {
            for change in receipt.changes {
                lines.append("| `\(escape(change.identity))` | `\(escape(pinLabel(change.oldPin)))` | `\(escape(pinLabel(change.newPin)))` | \(change.classification.rawValue) | **\(change.severity.rawValue)** |")
            }
        }
        let findings = receipt.changes.flatMap(\.findings).filter { $0.severity >= .review }
        if !findings.isEmpty {
            lines += ["", "### Findings", ""]
            for finding in findings {
                lines.append("- **\(finding.severity.rawValue)** `\(finding.code.rawValue)` — \(finding.message)")
            }
        }
        lines += [
            "", "Policy: `\(receipt.policy.source)` · \(receipt.policy.passed ? "passed" : "needs attention")",
            "", "> A `pass` means no configured policy was violated. It is not a universal safety guarantee and does not replace compiling or tests.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func pinLabel(_ pin: PinSnapshot?) -> String {
        guard let pin else { return "—" }
        switch pin.pinType {
        case .version: return pin.version ?? "unknown"
        case .branch: return "branch:\(pin.branch ?? "unknown")"
        case .revision: return "revision:\(pin.revision.map { String($0.prefix(8)) } ?? "unknown")"
        case .unknown: return "unknown"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
