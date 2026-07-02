import Testing
import SwiftServeCore
@testable import SwiftServeBuild

@Suite("Per-package roll-up, the health cross, ranking, and the cost verdict")
struct BuildCostAnalyzerTests {

    // MARK: - Builders

    private func mod(_ name: String, _ ms: Int, origin: CostOrigin = .dependency,
                     pkg: String? = nil, tc: Int = 0) -> ModuleTiming {
        ModuleTiming(module: name, packageIdentity: pkg, origin: origin, frontendWallMs: ms, typeCheckWallMs: tc)
    }
    private func built(compiled: Int = 10) -> BuildContext {
        BuildContext(buildSucceeded: true, compiledUnits: compiled, totalTypeCheckMs: nil, source: .build)
    }
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.05 }

    /// AppCore 400 + AppUI 250 (yours); swift-nio = NIOCore 600 + NIOPosix 300; big-lib 500;
    /// one unattributed module 50.  Total = 2100.
    private var timings: [ModuleTiming] {
        [
            mod("AppCore", 400, origin: .yourTarget),
            mod("AppUI", 250, origin: .yourTarget),
            mod("NIOCore", 600, pkg: "swift-nio"),
            mod("NIOPosix", 300, pkg: "swift-nio"),
            mod("BigLib", 500, pkg: "big-lib"),
            mod("Weird", 50, origin: .unattributed),
        ]
    }
    private func health(bigLib: Int) -> [String: DependencyHealth] {
        [
            "swift-nio": DependencyHealth(identity: "swift-nio", score: 82, flags: [], version: "2.101.1"),
            "big-lib": DependencyHealth(identity: "big-lib", score: bigLib,
                                        flags: ["stale", "single-maintainer"], version: "0.3.0"),
        ]
    }

    // MARK: - Tests

    @Test("dependency modules roll up to one package row; your targets stay broken out")
    func rollsUpAndRanks() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())

        // 5 rows: swift-nio, big-lib, AppCore, AppUI, (unattributed) — ranked by cost.
        #expect(r.entries.map(\.name) == ["swift-nio", "big-lib", "AppCore", "AppUI", "(unattributed)"])

        let nio = try #require(r.entries.first { $0.name == "swift-nio" })
        #expect(nio.origin == .dependency)
        #expect(nio.frontendWallMs == 900)     // 600 + 300, two modules collapsed
        #expect(nio.moduleCount == 2)
        #expect(nio.packageVersion == "2.101.1")
    }

    @Test("shares are computed against the whole build and rounded to 0.1")
    func sharePercentages() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())
        func share(_ name: String) throws -> Double { try #require(r.entries.first { $0.name == name }).sharePercent }

        #expect(close(try share("swift-nio"), 42.9))      // 900 / 2100
        #expect(close(try share("big-lib"), 23.8))        // 500 / 2100
        #expect(close(try share("AppCore"), 19.0))        // 400 / 2100
        #expect(close(try share("(unattributed)"), 2.4))  // 50 / 2100
    }

    @Test("an expensive AND unhealthy dependency is highlighted; a healthy heavy one is not")
    func expensiveAndUnhealthyHighlight() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())

        let big = try #require(r.entries.first { $0.name == "big-lib" })
        #expect(big.highlight == .expensiveAndUnhealthy)
        #expect(big.healthScore == 45)
        #expect(big.healthFlags.contains("stale"))
        #expect(big.note.contains("worth revisiting"))

        // swift-nio is heavier (42.9%) but healthy (82) — no callout.
        let nio = try #require(r.entries.first { $0.name == "swift-nio" })
        #expect(nio.highlight == .none)
    }

    @Test("the costliest first-party target is flagged as the slowest to compile")
    func slowestTargetHighlight() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())
        let appCore = try #require(r.entries.first { $0.name == "AppCore" })
        let appUI = try #require(r.entries.first { $0.name == "AppUI" })
        #expect(appCore.highlight == .slowestTarget)
        #expect(appUI.highlight == .none)
    }

    @Test("a lone first-party target is never called 'slowest'")
    func singleTargetNotHighlighted() throws {
        let r = BuildCostAnalyzer.analyze(
            timings: [mod("OnlyTarget", 300, origin: .yourTarget), mod("Dep", 200, pkg: "dep")],
            health: [:], context: built())
        let only = try #require(r.entries.first { $0.name == "OnlyTarget" })
        #expect(only.highlight == .none)
    }

    @Test("with no health map, dependencies carry nil health and are never flagged unhealthy")
    func noHealthMap() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: [:], context: built())
        let big = try #require(r.entries.first { $0.name == "big-lib" })
        #expect(big.healthScore == nil)
        #expect(big.highlight == .none)
        #expect(r.summary.healthCrossed == false)
        // The slowest-target callout still works without any health.
        #expect(r.entries.first { $0.name == "AppCore" }?.highlight == .slowestTarget)
    }

    @Test("summary splits cost across your code, dependencies, and unattributed")
    func summarySplits() {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())
        let s = r.summary
        #expect(s.totalFrontendWallMs == 2100)
        #expect(s.yourCodeWallMs == 650)        // 400 + 250
        #expect(s.dependencyWallMs == 1400)     // 900 + 500
        #expect(s.unattributedWallMs == 50)
        #expect(s.targetCount == 2)
        #expect(s.dependencyCount == 2)
        #expect(s.entryCount == 5)
        #expect(s.moduleCount == 6)
        #expect(s.healthCrossed == true)
    }

    @Test("an expensive-unhealthy dependency drives a soft-squeeze verdict that names it")
    func verdictNamesUnhealthyDep() {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 45), context: built())
        #expect(r.verdict.mood == .softSqueeze)
        #expect(r.verdict.headline.contains("big-lib"))
    }

    @Test("when every heavy dependency is healthy, the verdict reassures and names the heaviest")
    func verdictReassuresWhenHealthy() throws {
        let r = BuildCostAnalyzer.analyze(timings: timings, health: health(bigLib: 90), context: built())
        let big = try #require(r.entries.first { $0.name == "big-lib" })
        #expect(big.highlight == .none)   // unwrap first — bare `.none` would bind to Optional.none
        #expect(r.verdict.mood == .freshSwirl)
        #expect(r.verdict.headline.contains("swift-nio"))
    }

    @Test("multiple unattributed modules collapse into one bucket")
    func unattributedBucket() throws {
        let r = BuildCostAnalyzer.analyze(
            timings: [mod("X", 30, origin: .unattributed), mod("Y", 20, origin: .unattributed)],
            health: [:], context: built())
        let bucket = try #require(r.entries.first { $0.origin == .unattributed })
        #expect(bucket.name == "(unattributed)")
        #expect(bucket.frontendWallMs == 50)
        #expect(bucket.moduleCount == 2)
    }

    @Test("a cached build is reported as cached, not a false all-clear")
    func cachedBuildVerdict() {
        let cached = BuildContext(buildSucceeded: true, compiledUnits: 0, totalTypeCheckMs: nil, source: .build)
        let r = BuildCostAnalyzer.analyze(timings: [], health: [:], context: cached)
        #expect(r.summary.cachedBuild)
        #expect(r.verdict.headline.contains("Cached"))
        #expect(r.verdict.mood == .freshSwirl)
    }
}
