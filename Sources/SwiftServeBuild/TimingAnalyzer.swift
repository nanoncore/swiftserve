import Foundation
import SwiftServeCore

/// Turns raw timing records into the product: a ranked list of build-time pointers, a
/// headline summary, and Swiftee's (encouraging) verdict. Pure and synchronous — feed it
/// records + config + the build context, get a `Result`. No I/O, no real build.
///
/// Ranking is the whole point: a flat list of 200 slow expressions is noise. We sort by
/// measured cost, surface a headline ("~X of type-checking is in N hot spots"), and let the
/// CLI cap the detail at top-N with a "+ M more" rollup.
public enum TimingAnalyzer {

    public struct Result: Sendable, Equatable {
        public let pointers: [Pointer]                 // ranked, full set (over threshold)
        public let summary: BuildTimingReport.Summary
        public let verdict: BuildTimingReport.Verdict
    }

    /// Path fragments that mark a file as NOT first-party — dependency checkouts and build
    /// products. Slice 4 is first-party only; dependency-cost pointers are a later slice, so
    /// we drop these here and leave the seam clean.
    public static let dependencyPathMarkers =
        ["/.build/", "/checkouts/", "/SourcePackages/", "/DerivedData/", "/Index.noindex/"]

    /// A timing belongs to first-party code unless its path runs through a dependency
    /// checkout or a build-products tree.
    public static func isFirstParty(_ path: String) -> Bool {
        !dependencyPathMarkers.contains { path.contains($0) }
    }

    public static func analyze(records: [TimingRecord],
                               context: BuildContext,
                               config: TimingConfig = .default) -> Result {
        // 1. Keep only sites over their category's configured threshold. (The compiler
        //    already filtered when driving a build; re-applying keeps an ingested log — and
        //    the unit tests — honest about the bar.)
        let overThreshold = records.filter { $0.costMs >= config.threshold(for: $0.category) }

        // 2. First-party only this slice — drop dependency hot spots, but remember how many,
        //    so the CLI can say so out loud instead of silently hiding them.
        let firstParty = overThreshold.filter { isFirstParty($0.location.file) }
        let dependencyIgnored = overThreshold.count - firstParty.count

        // 3. Collapse duplicate sites (same file:line:col + category compiled in more than
        //    one target/arch), keeping the worst cost.
        let deduped = dedupeKeepingMax(firstParty)

        // 3. Rank by cost, most expensive first; stable tiebreak by file then line.
        let ranked = deduped.sorted { a, b in
            if a.costMs != b.costMs { return a.costMs > b.costMs }
            if a.location.file != b.location.file { return a.location.file < b.location.file }
            return a.location.line < b.location.line
        }

        let pointers = ranked.map { makePointer($0, config: config) }
        let summary = makeSummary(pointers, context: context, config: config,
                                  dependencyIgnored: dependencyIgnored)
        let verdict = makeVerdict(pointers, summary: summary, context: context)
        return Result(pointers: pointers, summary: summary, verdict: verdict)
    }

    // MARK: - Pointer construction

    private static func makePointer(_ r: TimingRecord, config: TimingConfig) -> Pointer {
        let threshold = config.threshold(for: r.category)
        let impact = config.tier(for: r.costMs)

        switch r.category {
        case .slowExpression:
            return Pointer(
                category: .slowExpression, location: r.location, costMs: r.costMs, thresholdMs: threshold,
                impact: impact,
                explanation: "Type-checking this expression takes \(r.costMs)ms — past the \(threshold)ms bar. "
                    + "That's usually the compiler grinding through a thicket of operator and overload inference.",
                suggestion: config.copy.expressionSuggestion,
                decl: nil)

        case .slowFunctionBody:
            let declText = r.subject ?? "this function body"
            let isViewBody = (r.subject?.contains("'body'") ?? false)
            return Pointer(
                category: .slowFunctionBody, location: r.location, costMs: r.costMs, thresholdMs: threshold,
                impact: impact,
                explanation: "Type-checking \(declText) takes \(r.costMs)ms — past the \(threshold)ms bar. "
                    + "The body is large or inference-heavy enough that the compiler can't solve it quickly.",
                suggestion: isViewBody ? config.copy.viewBodySuggestion : config.copy.functionBodySuggestion,
                decl: r.subject)
        }
    }

    private static func dedupeKeepingMax(_ records: [TimingRecord]) -> [TimingRecord] {
        var best: [String: TimingRecord] = [:]
        for r in records {
            let key = "\(r.location.file)|\(r.location.line)|\(r.location.column)|\(r.category.rawValue)"
            if let existing = best[key], existing.costMs >= r.costMs { continue }
            best[key] = r
        }
        return Array(best.values)
    }

    // MARK: - Summary

    private static func makeSummary(_ pointers: [Pointer],
                                    context: BuildContext,
                                    config: TimingConfig,
                                    dependencyIgnored: Int) -> BuildTimingReport.Summary {
        let flagged = pointers.count
        let detailed = min(config.topN, flagged)
        let topNRecoverable = pointers.prefix(detailed).reduce(0) { $0 + $1.costMs }
        let totalFlagged = pointers.reduce(0) { $0 + $1.costMs }
        return BuildTimingReport.Summary(
            flaggedSiteCount: flagged,
            slowExpressionCount: pointers.filter { $0.category == .slowExpression }.count,
            slowFunctionBodyCount: pointers.filter { $0.category == .slowFunctionBody }.count,
            detailedCount: detailed,
            rolledUpCount: flagged - detailed,
            topNRecoverableMs: topNRecoverable,
            totalFlaggedMs: totalFlagged,
            totalTypeCheckMs: context.totalTypeCheckMs,
            dependencySitesIgnored: dependencyIgnored,
            buildSucceeded: context.buildSucceeded,
            cachedBuild: context.looksCached)
    }

    // MARK: - Verdict (Swiftee — encouraging, never scolding)

    private static func makeVerdict(_ pointers: [Pointer],
                                    summary: BuildTimingReport.Summary,
                                    context: BuildContext) -> BuildTimingReport.Verdict {
        // A cached build recompiled nothing, so there's almost nothing to measure — say so
        // plainly instead of falsely celebrating an empty result.
        if context.looksCached {
            return .init(mood: .freshSwirl,
                         voiceLine: "I only see files that actually recompiled — looks like a cached build.",
                         headline: "Cached build — re-run with --clean for full coverage.")
        }

        if pointers.isEmpty {
            return .init(mood: .partyMode,
                         voiceLine: "Nothing slow enough to flag — your build's in good shape.",
                         headline: "No expressions or function bodies over the timing thresholds.")
        }

        let recoverable = formatMs(summary.topNRecoverableMs)
        let spots = summary.detailedCount
        let spotsLabel = "\(spots) hot spot\(spots == 1 ? "" : "s")"
        let headline: String
        if let total = summary.totalTypeCheckMs {
            headline = "~\(recoverable) of your ~\(formatMs(total)) type-check time is in \(spotsLabel)."
        } else {
            headline = "~\(recoverable) of type-checking is concentrated in \(spotsLabel)."
        }
        return .init(mood: .freshSwirl,
                     voiceLine: "Nail these and your builds get noticeably snappier.",
                     headline: headline)
    }

    // MARK: - Formatting (shared with the CLI renderer)

    /// Human duration: seconds with one decimal once we're past a second, else milliseconds.
    public static func formatMs(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }
}
