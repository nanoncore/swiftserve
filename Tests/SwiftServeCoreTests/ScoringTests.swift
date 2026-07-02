import Foundation
import Testing
@testable import SwiftServeCore

@Suite("Scoring (file-only)")
struct ScoringTests {
    let fixedTime = "2026-06-24T00:00:00Z"

    // MARK: helpers

    func versionPin(_ id: String, _ version: String, owner: String = "apple", host: String = "github.com") -> Pin {
        Pin(identity: id, kind: .remoteSourceControl,
            location: "https://\(host)/\(owner)/\(id).git",
            resolvedVersion: version, branch: nil, revision: "abc123", pinType: .version)
    }
    func branchPin(_ id: String, _ branch: String = "main") -> Pin {
        Pin(identity: id, kind: .remoteSourceControl,
            location: "https://github.com/someone/\(id).git",
            resolvedVersion: nil, branch: branch, revision: "abc123", pinType: .branch)
    }

    func report(_ pins: [Pin], config: ScoringConfig = .default) -> Report {
        Scorer(config: config).buildReport(
            pins: pins, enrichment: [:], source: "fileOnly", networkUsed: false, generatedAt: fixedTime)
    }

    // MARK: tests

    @Test("A clean, fully version-pinned project lands in softSqueeze (honest, not flattering)")
    func cleanProjectIsSoftSqueeze() async throws {
        let r = try await Analyzer().analyze(resolved: fixtureData("resolved-v2"), generatedAt: fixedTime)
        #expect(r.overall.mood == .softSqueeze)
        #expect((55...79).contains(r.overall.score))
        #expect(r.overall.score == 67) // documents the shipped defaults
        #expect(r.enrichment.source == "fileOnly")
        #expect(r.enrichment.networkUsed == false)
    }

    @Test("Branch and revision pins score lower than releases and raise the right flags")
    func smellyPinsScoreLower() async throws {
        let r = try await Analyzer().analyze(resolved: fixtureData("resolved-v3"), generatedAt: fixedTime)

        let log = try #require(r.packages.first { $0.identity == "swift-log" })
        let branch = try #require(r.packages.first { $0.identity == "experimental-lib" })
        let revision = try #require(r.packages.first { $0.identity == "pinned-fork" })

        #expect(branch.flags.contains("branchPin"))
        #expect(revision.flags.contains("revisionPin"))
        #expect(log.score > branch.score)
        #expect(log.score > revision.score)
        #expect(branch.reason.contains("main"))
    }

    @Test("A branch-pin-heavy project melts down")
    func branchHeavyMeltsDown() {
        let r = report([branchPin("a"), branchPin("b"), branchPin("c")])
        #expect(r.overall.mood == .meltdown)
    }

    @Test("v3 (with smells) scores below the clean v2 set")
    func relativeOrdering() async throws {
        let v2 = try await Analyzer().analyze(resolved: fixtureData("resolved-v2"), generatedAt: fixedTime)
        let v3 = try await Analyzer().analyze(resolved: fixtureData("resolved-v3"), generatedAt: fixedTime)
        #expect(v3.overall.score < v2.overall.score)
    }

    @Test("Registry pins are flagged as such")
    func registryFlag() async throws {
        let r = try await Analyzer().analyze(resolved: fixtureData("resolved-v2"), generatedAt: fixedTime)
        let collections = try #require(r.packages.first { $0.identity == "swift-collections" })
        #expect(collections.flags.contains("registry"))
    }

    @Test("Raising the neutral baseline raises the overall score (config is honored)")
    func configOverride() {
        let pins = [versionPin("swift-nio", "2.65.0"), versionPin("swift-log", "1.5.4")]
        let base = report(pins).overall.score
        let generous = report(pins, config: ScoringConfig(neutralBaseline: 90)).overall.score
        #expect(generous > base)
    }

    @Test("An empty resolved file is, from a supply-chain view, immaculate")
    func emptyIsParty() {
        let r = report([])
        #expect(r.overall.score == 100)
        #expect(r.overall.mood == .partyMode)
        #expect(r.graph.total == 0)
    }

    @Test("A fork pinned alongside its upstream is detected as a duplicate name")
    func duplicateForkDetected() {
        let pins = [
            Pin(identity: "foo", kind: .remoteSourceControl, location: "https://github.com/apple/foo.git",
                resolvedVersion: "1.0.0", branch: nil, revision: "a", pinType: .version),
            Pin(identity: "foo-fork", kind: .remoteSourceControl, location: "https://github.com/evil/foo.git",
                resolvedVersion: "1.0.0", branch: nil, revision: "b", pinType: .version),
        ]
        let r = report(pins)
        #expect(r.graph.duplicates.count == 1)
        #expect(r.graph.duplicates.first?.name == "foo")
    }

    @Test("Graph metrics that need the manifest are reported as unknown, not guessed")
    func graphHonesty() {
        let r = report([versionPin("swift-nio", "2.65.0")])
        #expect(r.graph.direct == nil)
        #expect(r.graph.transitive == nil)
        #expect(r.graph.maxDepth == nil)
    }

    @Test("Report encodes mood as its canonical string")
    func moodEncodesAsString() throws {
        let r = report([branchPin("a"), branchPin("b"), branchPin("c")])
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"meltdown\""))
    }
}
