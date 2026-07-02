import Testing
import SwiftServeCore
@testable import SwiftServeBuild

@Suite("Ranking, thresholds, and the Swiftee verdict")
struct TimingAnalyzerTests {

    /// A compiled-clean build context (files recompiled, build succeeded, no aggregate total).
    private func built(compiled: Int = 8, total: Int? = nil) -> BuildContext {
        BuildContext(buildSucceeded: true, compiledUnits: compiled, totalTypeCheckMs: total, source: .build)
    }

    private func expr(_ file: String, _ ms: Int) -> TimingRecord {
        TimingRecord(category: .slowExpression, location: CodeLocation(file: file, line: 1, column: 1),
                     costMs: ms, limitMs: 100, subject: nil)
    }
    private func body(_ file: String, _ ms: Int, subject: String = "func f()") -> TimingRecord {
        TimingRecord(category: .slowFunctionBody, location: CodeLocation(file: file, line: 1, column: 1),
                     costMs: ms, limitMs: 200, subject: subject)
    }

    @Test("pointers rank by cost, sub-threshold records are filtered out")
    func ranksAndFilters() {
        let records = [
            expr("A.swift", 150),
            expr("B.swift", 900),
            body("C.swift", 500),
            expr("D.swift", 50),    // below the 100ms expression threshold → dropped
            body("E.swift", 100),   // below the 200ms body threshold → dropped
            body("F.swift", 250),
        ]
        let result = TimingAnalyzer.analyze(records: records, context: built())

        // 4 survive (900, 500, 250, 150), ranked most-expensive first.
        #expect(result.pointers.map(\.costMs) == [900, 500, 250, 150])
        #expect(result.summary.flaggedSiteCount == 4)
        #expect(result.summary.totalFlaggedMs == 1800)

        // Impact tiers follow the default cutoffs (critical ≥ 800, high ≥ 400).
        #expect(result.pointers.map(\.impact) == [.critical, .high, .moderate, .moderate])
    }

    @Test("top-N caps the detailed list and the rollup counts the rest")
    func topNCapAndRollup() {
        let records = (1...7).map { expr("F\($0).swift", $0 * 100) } // 100…700, all over threshold
        let cfg = TimingConfig.default.with(topN: 3)
        let result = TimingAnalyzer.analyze(records: records, context: built(), config: cfg)

        #expect(result.summary.flaggedSiteCount == 7)
        #expect(result.summary.detailedCount == 3)
        #expect(result.summary.rolledUpCount == 4)
        // Top 3 are 700 + 600 + 500.
        #expect(result.summary.topNRecoverableMs == 1800)
        #expect(result.summary.totalFlaggedMs == 100 + 200 + 300 + 400 + 500 + 600 + 700)
    }

    @Test("duplicate sites collapse to the worst cost")
    func dedupesKeepingMax() {
        let records = [
            TimingRecord(category: .slowExpression, location: CodeLocation(file: "X.swift", line: 4, column: 9),
                         costMs: 300, limitMs: 100, subject: nil),
            TimingRecord(category: .slowExpression, location: CodeLocation(file: "X.swift", line: 4, column: 9),
                         costMs: 500, limitMs: 100, subject: nil),   // same site, compiled twice
        ]
        let result = TimingAnalyzer.analyze(records: records, context: built())
        #expect(result.pointers.count == 1)
        #expect(result.pointers.first?.costMs == 500)
    }

    @Test("below-threshold-only input → celebratory all-clear, no pointers")
    func allClearWhenNothingSlow() {
        let records = [expr("A.swift", 40), body("B.swift", 120)]   // both under their thresholds
        let result = TimingAnalyzer.analyze(records: records, context: built())

        #expect(result.pointers.isEmpty)
        #expect(result.summary.flaggedSiteCount == 0)
        #expect(result.verdict.mood == .partyMode)
        #expect(result.verdict.headline.contains("No expressions or function bodies"))
    }

    @Test("a cached build is reported as cached, never as a false all-clear")
    func cachedBuildVerdict() {
        let context = BuildContext(buildSucceeded: true, compiledUnits: 0, totalTypeCheckMs: nil, source: .build)
        let result = TimingAnalyzer.analyze(records: [], context: context)

        #expect(result.pointers.isEmpty)
        #expect(result.summary.cachedBuild)
        #expect(result.verdict.mood != .partyMode)          // not a celebration
        #expect(result.verdict.headline.contains("Cached build"))
    }

    @Test("the aggregate total, when present, anchors the headline")
    func headlineUsesAggregateTotal() {
        let records = [expr("A.swift", 1500), body("B.swift", 800)]
        let result = TimingAnalyzer.analyze(records: records, context: built(total: 14_000))
        // ~2.3s of your ~14.0s type-check time …
        #expect(result.verdict.headline.contains("2.3s"))
        #expect(result.verdict.headline.contains("14.0s"))
    }

    @Test("dependency timings are set aside — first-party only this slice")
    func dropsDependencyHotSpots() {
        let records = [
            expr("/Users/me/App/Sources/Mine.swift", 900),
            expr("/Users/me/App/.build/checkouts/swift-syntax/Sources/Dep.swift", 1200),
            body("/Users/me/App/.build/checkouts/swift-syntax/Sources/Other.swift", 800),
        ]
        let result = TimingAnalyzer.analyze(records: records, context: built())

        // Only the first-party site survives; the two dependency sites are counted, not shown.
        #expect(result.pointers.count == 1)
        #expect(result.pointers.first?.location.file.hasSuffix("Mine.swift") == true)
        #expect(result.summary.dependencySitesIgnored == 2)
    }

    @Test("a SwiftUI `body` gets the subview-oriented suggestion")
    func viewBodyGetsTailoredCopy() {
        let cfg = TimingConfig.default
        let viewBody = body("View.swift", 900, subject: "getter for 'body'")
        let plain = body("Service.swift", 900, subject: "instance method 'load()'")
        let result = TimingAnalyzer.analyze(records: [viewBody, plain], context: built(), config: cfg)

        let v = try! #require(result.pointers.first { $0.location.file.hasSuffix("View.swift") })
        let s = try! #require(result.pointers.first { $0.location.file.hasSuffix("Service.swift") })
        #expect(v.suggestion == cfg.copy.viewBodySuggestion)
        #expect(s.suggestion == cfg.copy.functionBodySuggestion)
        #expect(v.decl == "getter for 'body'")
    }
}
