import Foundation
import SwiftServeCore

/// Turns per-module timings into the product: a ranked list of build-cost entries (your targets
/// and your dependency packages), a share-aware summary, and Swiftee's verdict. Pure and
/// synchronous — feed it timings + offline health + the build context, get a `Result`. No I/O.
///
/// The two jobs that matter: (1) roll dependency *modules* up to their *package* (swift-nio's
/// eleven modules become one `swift-nio` row), keeping your own targets broken out so the
/// slowest is actionable; (2) cross each dependency with its offline health so "reconsider this
/// dependency" only fires when a package is both expensive AND unhealthy.
public enum BuildCostAnalyzer {

    public struct Result: Sendable, Equatable {
        public let entries: [BuildCostEntry]
        public let summary: BuildCostReport.Summary
        public let verdict: BuildCostReport.Verdict
    }

    public static func analyze(timings: [ModuleTiming],
                               health: [String: DependencyHealth] = [:],
                               context: BuildContext,
                               config: CostConfig = .default) -> Result {
        // 1. Roll up into keyed buckets: first-party per TARGET, dependencies per PACKAGE,
        //    everything unattributed into a single bucket.
        struct Acc {
            var name: String
            var origin: CostOrigin
            var frontend = 0
            var typeCheck = 0
            var modules = 0
            var version: String?
            var healthScore: Int?
            var healthFlags: [String] = []
        }
        var order: [String] = []
        var accs: [String: Acc] = [:]

        func key(_ t: ModuleTiming) -> String {
            switch t.origin {
            case .yourTarget: return "t:\(t.module)"
            case .dependency: return "d:\(t.packageIdentity ?? t.module)"
            case .unattributed: return "u:"
            }
        }
        func displayName(_ t: ModuleTiming) -> String {
            switch t.origin {
            case .yourTarget: return t.module
            case .dependency: return t.packageIdentity ?? t.module
            case .unattributed: return "(unattributed)"
            }
        }

        for t in timings {
            let k = key(t)
            if accs[k] == nil {
                order.append(k)
                var acc = Acc(name: displayName(t), origin: t.origin)
                if t.origin == .dependency, let id = t.packageIdentity, let h = health[id] {
                    acc.version = h.version; acc.healthScore = h.score; acc.healthFlags = h.flags
                }
                accs[k] = acc
            }
            accs[k]?.frontend += t.frontendWallMs
            accs[k]?.typeCheck += t.typeCheckWallMs
            accs[k]?.modules += 1
        }

        let total = accs.values.reduce(0) { $0 + $1.frontend }

        // 2. Decide highlights up front (they need the whole set): the costliest first-party
        //    target, and any dependency that is both expensive AND unhealthy.
        let targetKeys = order.filter { accs[$0]?.origin == .yourTarget }
        let slowestTargetKey = targetKeys.max { (accs[$0]?.frontend ?? 0) < (accs[$1]?.frontend ?? 0) }

        func share(_ ms: Int) -> Double { total > 0 ? round1(100.0 * Double(ms) / Double(total)) : 0 }

        // 3. Build the ranked entries.
        var entries: [BuildCostEntry] = order.compactMap { k in
            guard let a = accs[k] else { return nil }
            let pct = share(a.frontend)

            var highlight: CostHighlight = .none
            var note = ""
            if a.origin == .yourTarget, k == slowestTargetKey, a.frontend > 0, targetKeys.count > 1 {
                highlight = .slowestTarget
                note = "Your slowest target to compile — the biggest first-party win if builds feel slow."
            } else if a.origin == .dependency, let hs = a.healthScore,
                      pct >= config.expensiveSharePercent, hs <= config.unhealthyScoreMax {
                highlight = .expensiveAndUnhealthy
                let why = a.healthFlags.isEmpty ? "" : " (\(a.healthFlags.prefix(2).joined(separator: ", ")))"
                note = "\(formatShare(pct)) of build cost and health \(hs)\(why) — an expensive bet worth revisiting."
            }

            return BuildCostEntry(
                name: a.name, origin: a.origin,
                frontendWallMs: a.frontend, typeCheckWallMs: a.typeCheck,
                sharePercent: pct, moduleCount: a.modules,
                packageVersion: a.version, healthScore: a.healthScore,
                healthFlags: a.healthFlags, highlight: highlight, note: note)
        }

        // Rank by cost, most expensive first; stable tiebreak by name.
        entries.sort { a, b in
            if a.frontendWallMs != b.frontendWallMs { return a.frontendWallMs > b.frontendWallMs }
            return a.name < b.name
        }

        let summary = makeSummary(entries, total: total, health: health, context: context)
        let verdict = makeVerdict(entries, summary: summary, context: context, config: config)
        return Result(entries: entries, summary: summary, verdict: verdict)
    }

    // MARK: - Summary

    private static func makeSummary(_ entries: [BuildCostEntry], total: Int,
                                    health: [String: DependencyHealth],
                                    context: BuildContext) -> BuildCostReport.Summary {
        func wall(_ o: CostOrigin) -> Int { entries.filter { $0.origin == o }.reduce(0) { $0 + $1.frontendWallMs } }
        let yours = wall(.yourTarget), deps = wall(.dependency), un = wall(.unattributed)
        func share(_ ms: Int) -> Double { total > 0 ? round1(100.0 * Double(ms) / Double(total)) : 0 }
        return BuildCostReport.Summary(
            totalFrontendWallMs: total,
            yourCodeWallMs: yours, dependencyWallMs: deps, unattributedWallMs: un,
            yourCodeSharePercent: share(yours), dependencySharePercent: share(deps),
            entryCount: entries.count,
            targetCount: entries.filter { $0.origin == .yourTarget }.count,
            dependencyCount: entries.filter { $0.origin == .dependency }.count,
            moduleCount: entries.reduce(0) { $0 + $1.moduleCount },
            healthCrossed: !health.isEmpty,
            buildSucceeded: context.buildSucceeded,
            cachedBuild: context.looksCached)
    }

    // MARK: - Verdict (Swiftee — encouraging, names the one thing worth knowing)

    private static func makeVerdict(_ entries: [BuildCostEntry],
                                    summary: BuildCostReport.Summary,
                                    context: BuildContext,
                                    config: CostConfig) -> BuildCostReport.Verdict {
        if context.looksCached {
            return .init(mood: .freshSwirl,
                         voiceLine: "I only measured what actually recompiled.",
                         headline: "Cached build — re-run with --clean for full per-dependency cost.")
        }
        if entries.isEmpty || summary.totalFrontendWallMs == 0 {
            return .init(mood: .freshSwirl,
                         voiceLine: "There wasn't any compile timing to read this run.",
                         headline: "Nothing to measure — try --clean for a full build.")
        }

        let unhealthy = entries.filter { $0.highlight == .expensiveAndUnhealthy }
        if let worst = unhealthy.first {
            let more = unhealthy.count > 1 ? " (and \(unhealthy.count - 1) other\(unhealthy.count - 1 == 1 ? "" : "s"))" : ""
            return .init(mood: .softSqueeze,
                         voiceLine: "Most of your build cost is fine — one dependency stands out\(more.isEmpty ? "" : ", plus a few more").",
                         headline: "\(worst.name) is \(formatShare(worst.sharePercent)) of your build cost and looks unhealthy\(more) — worth a look.")
        }

        // Healthy path: name the heaviest dependency (reassure) and the slowest target (act).
        let topDep = entries.first { $0.origin == .dependency }
        let slowest = entries.first { $0.highlight == .slowestTarget } ?? entries.first { $0.origin == .yourTarget }
        var bits: [String] = []
        if let d = topDep { bits.append("\(d.name) is your heaviest dependency at \(formatShare(d.sharePercent)) — and it's healthy") }
        if let s = slowest { bits.append("your slowest target is \(s.name)") }
        let headline = bits.isEmpty
            ? "Build cost is spread evenly — nothing stands out."
            : bits.joined(separator: "; ") + "."
        let lightAndHealthy = (topDep?.sharePercent ?? 0) < config.expensiveSharePercent
        return .init(mood: lightAndHealthy ? .partyMode : .freshSwirl,
                     voiceLine: lightAndHealthy
                        ? "Light dependency footprint, all well-maintained. Tidy."
                        : "Nothing alarming — just know where your build time goes.",
                     headline: headline)
    }

    // MARK: - Formatting

    /// Round a percentage to one decimal place.
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// A share rendered like "25.6%".
    public static func formatShare(_ pct: Double) -> String {
        String(format: "%.1f%%", pct)
    }
}
