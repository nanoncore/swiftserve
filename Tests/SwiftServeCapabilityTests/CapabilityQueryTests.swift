import Foundation
import Testing
@testable import SwiftServeCapability

@Suite struct CapabilityQueryTests {

    private func makeDataset() -> CapabilityDataset {
        let taxonomy = Taxonomy(domain: "audio", capabilities: [
            .init(id: "audio.noise-cancellation", label: "Noise cancellation",
                  aliases: ["noise suppression", "krisp"]),
            .init(id: "audio.session-management", label: "Audio session management",
                  aliases: ["avaudiosession"]),
        ])
        func record(url: String, name: String, capability: String, label: String,
                    platforms: [String: PlatformClaim]) -> CapabilityRecord {
            CapabilityRecord(
                package: RecordPackage(canonicalURL: url, name: name, aliases: ["\(name)Client"],
                                       version: "2.0.0", commit: "abc", surfaceDigest: "fnv1a64:0"),
                capability: CapabilityRef(id: capability, label: label),
                platforms: platforms, labeledBy: "test", labeledAt: "2026-07-02T00:00:00Z")
        }
        let anchor = EvidenceAnchor(kind: .guard, symbol: "A.b", file: "Sources/A.swift", line: 1,
                                    condition: "os(iOS)")
        return CapabilityDataset(
            taxonomy: taxonomy,
            records: [
                record(url: "https://github.com/livekit/client-sdk-swift", name: "LiveKit",
                       capability: "audio.session-management", label: "Audio session management",
                       platforms: [
                           "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: []),
                           "macOS": PlatformClaim(status: .unsupported, confidence: 0.85, evidence: [anchor]),
                       ]),
                record(url: "https://github.com/audiokit/audiokit", name: "AudioKit",
                       capability: "audio.session-management", label: "Audio session management",
                       platforms: [
                           "macOS": PlatformClaim(status: .supported, confidence: 0.8, evidence: []),
                       ]),
            ])
    }

    @Test func checkResolvesAliasesAndFindsTheNearMiss() throws {
        let dataset = makeDataset()
        let report = try CapabilityQuery.check(dataset: dataset, package: "livekit",
                                               capability: "avaudiosession", platform: .macOS)
        #expect(report.verdict.status == .unsupported)
        #expect(report.query.capability == "audio.session-management")
        #expect(report.otherPlatforms["iOS"] == "supported")
        // The near-miss always hands you the alternative.
        #expect(report.alternatives.map(\.packageName) == ["AudioKit"])
        // The receipt carries a permalink to the deciding line at the pinned tag.
        #expect(report.evidence.first?.permalink
                == "https://github.com/livekit/client-sdk-swift/blob/2.0.0/Sources/A.swift#L1")
    }

    @Test func fuzzyCapabilityMatchingMeetsInTheMiddle() {
        let dataset = makeDataset()
        #expect(dataset.capability(matching: "audio session")?.id == "audio.session-management")
        #expect(dataset.capability(matching: "session-management")?.id == "audio.session-management")
        #expect(dataset.capability(matching: "KRISP")?.id == "audio.noise-cancellation")
        #expect(dataset.capability(matching: "quantum entanglement") == nil)
    }

    @Test func packageResolutionAcceptsURLNameAndAlias() {
        let dataset = makeDataset()
        for query in ["https://github.com/livekit/client-sdk-swift", "LiveKit", "livekitclient",
                      "git@github.com:livekit/client-sdk-swift.git"] {
            #expect(!dataset.packageRecords(matching: query).isEmpty, "failed for \(query)")
        }
        #expect(dataset.packageRecords(matching: "nonexistent").isEmpty)
    }

    @Test func missingPlatformClaimIsUnknownNotError() throws {
        let report = try CapabilityQuery.check(dataset: makeDataset(), package: "livekit",
                                               capability: "audio.session-management", platform: .watchOS)
        #expect(report.verdict.status == .unknown)
        #expect(report.swiftee.voiceLine == "Honest answer: not verified yet.")
    }

    @Test func unknownPackageAndCapabilityFailLoudly() {
        #expect(throws: CapabilityQuery.QueryError.self) {
            try CapabilityQuery.check(dataset: makeDataset(), package: "nope",
                                      capability: "krisp", platform: .iOS)
        }
        #expect(throws: CapabilityQuery.QueryError.self) {
            try CapabilityQuery.find(dataset: makeDataset(), capability: "nope", platform: .iOS)
        }
    }

    @Test func findRanksByStatusWeightTimesConfidenceAndHidesUnsupported() throws {
        let report = try CapabilityQuery.find(dataset: makeDataset(),
                                              capability: "audio.session-management", platform: .macOS)
        // LiveKit's macOS claim is unsupported → hidden by default.
        #expect(report.results.map(\.packageName) == ["AudioKit"])
        #expect(report.results[0].status == .supported)

        let withAll = try CapabilityQuery.find(dataset: makeDataset(),
                                               capability: "audio.session-management", platform: .macOS,
                                               includeUnsupported: true)
        #expect(withAll.results.contains { $0.packageName == "LiveKit" && $0.status == .unsupported })
    }

    @Test func schemaEnumsStayInSyncWithSwift() {
        #expect(CapabilitySchemas.platformEnum == Platform.allCases.map(\.rawValue))
        #expect(Set(CapabilitySchemas.statusEnum)
                == Set([ClaimStatus.supported, .unsupported, .conditional, .unknown].map(\.rawValue)))
        #expect(Set(CapabilitySchemas.evidenceKindEnum)
                == Set([EvidenceKind.symbol, .guard, .availability, .manifestPlatforms, .readme].map(\.rawValue)))
        for schema in [CapabilitySchemas.recordJSON, CapabilitySchemas.surfaceJSON] {
            #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil,
                    "schema constant must be valid JSON")
        }
    }
}
