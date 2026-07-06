import Foundation
import Testing
@testable import SwiftServeCapability

/// The engine that lets the index check itself: every bucket, every repair,
/// every flip — built on the same LiveKit-shaped world as the validator
/// tests, with an old surface at the pinned tag and a new one at the bump.
@Suite struct RecheckEngineTests {

    private let home = "https://github.com/livekit/client-sdk-swift"
    private let companion = "https://github.com/livekit/swift-krisp-noise-filter"
    private let oldCommit = "abc123"
    private let newCommit = "def789"
    private let newTag = "2.16.0"

    private let taxonomy = Taxonomy(domain: "audio", capabilities: [
        .init(id: "audio.noise-cancellation", label: "Noise cancellation"),
    ])

    // MARK: - World builders

    private func filterDecl(line: Int = 214, file: String = "Sources/LiveKit/Types/Options.swift",
                            macOS: PlatformPresence = .absent,
                            iOS: PlatformPresence = .present,
                            rawCondition: String? = "os(iOS)") -> SurfaceDecl {
        SurfaceDecl(name: "RoomOptions.noiseCancellationFilter", kind: .property,
                    signature: "var noiseCancellationFilter: AudioFilter?",
                    location: SurfaceLocation(file: file, line: line),
                    condition: .os("iOS"), rawCondition: rawCondition, availability: [],
                    resolvedPlatforms: ["iOS": iOS, "macOS": macOS, "watchOS": .absent,
                                        "tvOS": .absent, "visionOS": .absent,
                                        "macCatalyst": .present, "linux": .absent],
                    docSummary: nil, hasMacroAttributes: false)
    }

    private func urlDecl() -> SurfaceDecl {
        SurfaceDecl(name: "RoomOptions.url", kind: .property, signature: nil,
                    location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 30),
                    condition: nil, rawCondition: nil, availability: [],
                    resolvedPlatforms: Dictionary(uniqueKeysWithValues: Platform.allCases.map {
                        ($0.rawValue, PlatformPresence.present)
                    }),
                    docSummary: nil, hasMacroAttributes: false)
    }

    private func homeSurface(decls: [SurfaceDecl], tag: String, commit: String,
                             binaryTargets: Bool = false) -> PackageSurface {
        PackageSurface(
            package: PackageProvenance(canonicalURL: home, name: "client-sdk-swift",
                                       tag: tag, commit: commit),
            manifestPlatforms: [ManifestPlatform(platform: "iOS", minVersion: "13")],
            decls: decls,
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: decls.count,
                                parseFailures: 0, manifestUnparsed: false,
                                hasBinaryTargets: binaryTargets))
    }

    private func companionSurface() -> PackageSurface {
        let krisp = SurfaceDecl(
            name: "LiveKitKrispNoiseFilter", kind: .class, signature: nil,
            location: SurfaceLocation(file: "Sources/Krisp/Filter.swift", line: 10),
            condition: nil, rawCondition: nil, availability: [],
            resolvedPlatforms: Dictionary(uniqueKeysWithValues: Platform.allCases.map {
                ($0.rawValue, PlatformPresence.present)
            }),
            docSummary: nil, hasMacroAttributes: false)
        return PackageSurface(
            package: PackageProvenance(canonicalURL: companion, name: "krisp", tag: "0.0.8", commit: "kkk111"),
            manifestPlatforms: [], decls: [krisp],
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: 1,
                                parseFailures: 0, manifestUnparsed: false))
    }

    private func makeRecord(platforms: [String: PlatformClaim]) -> CapabilityRecord {
        CapabilityRecord(
            package: RecordPackage(canonicalURL: home, name: "LiveKit", aliases: [],
                                   version: "2.15.1", commit: oldCommit,
                                   surfaceDigest: "fnv1a64:old"),
            capability: CapabilityRef(id: "audio.noise-cancellation", label: "Noise cancellation"),
            platforms: platforms,
            labeledBy: "test", labeledAt: "2026-07-02T00:00:00Z")
    }

    private let symbolAnchor = EvidenceAnchor(
        kind: .symbol, symbol: "RoomOptions.noiseCancellationFilter",
        file: "Sources/LiveKit/Types/Options.swift", line: 214, condition: "os(iOS)")

    private let guardAnchor = EvidenceAnchor(
        kind: .guard, symbol: "RoomOptions.noiseCancellationFilter",
        file: "Sources/LiveKit/Types/Options.swift", line: 214, condition: "os(iOS)")

    /// The canonical validated record: iOS supported, macOS proven fenced.
    private func liveKitRecord() -> CapabilityRecord {
        makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [symbolAnchor]),
            "macOS": PlatformClaim(status: .unsupported, confidence: 0.85, evidence: [guardAnchor]),
        ])
    }

    private func input(record: CapabilityRecord, oldDecls: [SurfaceDecl]? = nil,
                       newDecls: [SurfaceDecl], newBinaryTargets: Bool = false,
                       includeCompanionInNew: Bool = true,
                       buildVerdicts: [String: BuildVerdict] = [:]) -> RecheckEngine.Input {
        let old = homeSurface(decls: oldDecls ?? [filterDecl(), urlDecl()],
                              tag: "2.15.1", commit: oldCommit)
        let new = homeSurface(decls: newDecls, tag: newTag, commit: newCommit,
                              binaryTargets: newBinaryTargets)
        var newSurfaces = [home: new]
        if includeCompanionInNew { newSurfaces[companion] = companionSurface() }
        return RecheckEngine.Input(
            record: record,
            oldSurfaces: [home: old, companion: companionSurface()],
            newSurfaces: newSurfaces,
            newDigests: [home: "fnv1a64:new"],
            newTag: newTag, newCommit: newCommit,
            buildVerdicts: buildVerdicts, taxonomy: taxonomy)
    }

    // MARK: - Still-true

    @Test func identicalDeclsBumpProvenanceAndNothingElse() {
        let record = liveKitRecord()
        let result = RecheckEngine.recheck(input(record: record,
                                                 newDecls: [filterDecl(), urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
        let proposed = try! #require(result.proposed)
        #expect(proposed.package.version == newTag)
        #expect(proposed.package.commit == newCommit)
        #expect(proposed.package.surfaceDigest == "fnv1a64:new")
        #expect(proposed.labeledAt == record.labeledAt)
        #expect(proposed.labeledBy == record.labeledBy)
        #expect(proposed.platforms == record.platforms)   // claims untouched
        #expect(result.anchors.allSatisfy { $0.change == .unchanged })
    }

    @Test func proposalRoundTripsThroughTheValidator() {
        let inp = input(record: liveKitRecord(), newDecls: [filterDecl(), urlDecl()])
        let proposed = try! #require(RecheckEngine.recheck(inp).proposed)
        let result = RecordValidator.validate(proposed, surfaces: inp.newSurfaces,
                                              digests: inp.newDigests, taxonomy: taxonomy)
        #expect(result.isAccepted, "\(result.errors)")
    }

    // MARK: - Anchor repair ladder

    @Test func pureLineMoveIsRepairedNotRotted() {
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [filterDecl(line: 250), urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
        #expect(result.anchors.contains { $0.change == .lineRepaired && $0.newLine == 250 })
        let proposed = try! #require(result.proposed)
        #expect(proposed.platforms["iOS"]!.evidence[0].line == 250)
        #expect(result.reason.contains("repaired"))
    }

    @Test func fileMoveOfAGloballyUniqueSymbolIsRepaired() {
        let moved = filterDecl(line: 12, file: "Sources/LiveKit/Options+Krisp.swift")
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [moved, urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
        #expect(result.anchors.contains {
            $0.change == .fileRepaired && $0.newFile == "Sources/LiveKit/Options+Krisp.swift"
        })
        let proposed = try! #require(result.proposed)
        #expect(proposed.platforms["iOS"]!.evidence[0].file == "Sources/LiveKit/Options+Krisp.swift")
        #expect(proposed.platforms["iOS"]!.evidence[0].line == 12)
    }

    @Test func duplicatedNameWithNoIdentifiableDeclIsAnchorGone() {
        // The symbol now exists twice in the anchor's file, neither at the
        // anchor's line — repair would be guessing, so it refuses.
        let twin = filterDecl(line: 400)
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [filterDecl(line: 300), twin, urlDecl()]))
        #expect(result.outcome == .anchorGone)
        #expect(result.anchors.contains { $0.change == .ambiguous })
    }

    @Test func removedSymbolIsAnchorGone() {
        let result = RecheckEngine.recheck(input(record: liveKitRecord(), newDecls: [urlDecl()]))
        #expect(result.outcome == .anchorGone)
        #expect(result.anchors.contains { $0.change == .unresolved })
        #expect(result.proposed == nil)
    }

    // MARK: - Presence flips

    @Test func fenceRemovedFlipsAbsentToPresent_truthChanged() {
        // macOS gains support upstream — the founding Krisp story. The record
        // says unsupported; the new surface says present. Never auto-bumped.
        let unfenced = filterDecl(macOS: .present, rawCondition: nil)
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [unfenced, urlDecl()]))
        #expect(result.outcome == .truthChanged)
        #expect(result.anchors.contains { $0.oldPresence == "absent" && $0.newPresence == "present" })
        #expect(result.proposed == nil)
    }

    @Test func guardAppearedFlipsPresentToConditional_truthChanged() {
        let guarded = filterDecl(iOS: .conditional("KRISP_SDK"))
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [guarded, urlDecl()]))
        #expect(result.outcome == .truthChanged)
        #expect(result.anchors.contains { $0.oldPresence == "present" && $0.newPresence == "conditional" })
    }

    @Test func conditionalToPresentIsCaught_theValidatorBlindSpot() {
        // A conditional claim whose guard fell away still VALIDATES (V03/V04
        // don't police conditional) — only the old-vs-new comparison sees it.
        let debugOld = SurfaceDecl(
            name: "RoomOptions.debugMode", kind: .property, signature: nil,
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 300),
            condition: .flag("LK_DEBUG"), rawCondition: "LK_DEBUG", availability: [],
            resolvedPlatforms: ["iOS": .conditional("LK_DEBUG")],
            docSummary: nil, hasMacroAttributes: false)
        let debugNew = SurfaceDecl(
            name: "RoomOptions.debugMode", kind: .property, signature: nil,
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 300),
            condition: nil, rawCondition: nil, availability: [],
            resolvedPlatforms: ["iOS": .present],
            docSummary: nil, hasMacroAttributes: false)
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "RoomOptions.debugMode",
                                    file: "Sources/LiveKit/Types/Options.swift", line: 300,
                                    condition: "LK_DEBUG")
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .conditional, confidence: 0.5, evidence: [anchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record, oldDecls: [debugOld, urlDecl()],
                                                 newDecls: [debugNew, urlDecl()]))
        #expect(result.outcome == .truthChanged)
        #expect(result.anchors.contains { $0.oldPresence == "conditional" && $0.newPresence == "present" })
    }

    @Test func conditionTextChangeWithSameStateIsMechanicallyRefreshed() {
        let old = SurfaceDecl(
            name: "RoomOptions.debugMode", kind: .property, signature: nil,
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 300),
            condition: .flag("LK_DEBUG"), rawCondition: "LK_DEBUG", availability: [],
            resolvedPlatforms: ["iOS": .conditional("LK_DEBUG")],
            docSummary: nil, hasMacroAttributes: false)
        let renamed = SurfaceDecl(
            name: "RoomOptions.debugMode", kind: .property, signature: nil,
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 300),
            condition: .flag("LK_DEBUG_V2"), rawCondition: "LK_DEBUG_V2", availability: [],
            resolvedPlatforms: ["iOS": .conditional("LK_DEBUG_V2")],
            docSummary: nil, hasMacroAttributes: false)
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "RoomOptions.debugMode",
                                    file: "Sources/LiveKit/Types/Options.swift", line: 300,
                                    condition: "LK_DEBUG")
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .conditional, confidence: 0.5, evidence: [anchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record, oldDecls: [old, urlDecl()],
                                                 newDecls: [renamed, urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
        #expect(result.anchors.contains { $0.conditionTextUpdated })
        let proposed = try! #require(result.proposed)
        #expect(proposed.platforms["iOS"]!.evidence[0].condition == "LK_DEBUG_V2")
    }

    @Test func flipOnAnUnknownClaimNeverBlocksTheBump() {
        // unknown is the honest floor — it cannot rot into falsehood. The
        // flip is reported as a finding; the bump proceeds.
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [symbolAnchor]),
            "macOS": PlatformClaim(status: .unknown, confidence: 0.3, evidence: [guardAnchor]),
        ])
        let unfenced = filterDecl(macOS: .present, rawCondition: nil)
        let result = RecheckEngine.recheck(input(record: record, newDecls: [unfenced, urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
        #expect(result.anchors.contains {
            $0.platform == "macOS" && $0.oldPresence == "absent" && $0.newPresence == "present"
        })
    }

    // MARK: - Companions

    @Test func companionAnchorsResolveAgainstTheCompanionSurface() {
        let krispAnchor = EvidenceAnchor(kind: .symbol, symbol: "LiveKitKrispNoiseFilter",
                                         file: "Sources/Krisp/Filter.swift", line: 10,
                                         package: companion)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.75,
                                 evidence: [symbolAnchor, krispAnchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record,
                                                 newDecls: [filterDecl(), urlDecl()]))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
    }

    @Test func missingCompanionSurfaceIsAnchorGone() {
        let krispAnchor = EvidenceAnchor(kind: .symbol, symbol: "LiveKitKrispNoiseFilter",
                                         file: "Sources/Krisp/Filter.swift", line: 10,
                                         package: companion)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.75,
                                 evidence: [symbolAnchor, krispAnchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record,
                                                 newDecls: [filterDecl(), urlDecl()],
                                                 includeCompanionInNew: false))
        #expect(result.outcome == .anchorGone)
    }

    // MARK: - Build verdicts

    private func verdict(_ outcome: BuildVerdict.Outcome, commit: String,
                         platform: String = "visionOS") -> [String: BuildVerdict] {
        let v = BuildVerdict(canonicalURL: home, commit: commit, platform: platform,
                             outcome: outcome, toolchain: "Xcode 26.6", sdk: "XROS26.5.sdk",
                             destination: "generic/platform=visionOS", scheme: "LiveKit",
                             errorExcerpt: outcome == .failed ? ["error: no such module 'UIKit'"] : [],
                             probedAt: "2026-07-03T00:00:00Z")
        return [v.key: v]
    }

    private let buildAnchor = EvidenceAnchor(kind: .buildVerdict, note: "probed with xcodebuild")

    @Test func buildVerdictRecordWithoutAFreshProbeNeedsProbe() {
        let record = makeRecord(platforms: [
            "visionOS": PlatformClaim(status: .unsupported, confidence: 0.9, evidence: [buildAnchor]),
        ])
        // A verdict exists — but at the OLD commit.
        let result = RecheckEngine.recheck(input(record: record, newDecls: [filterDecl(), urlDecl()],
                                                 buildVerdicts: verdict(.failed, commit: oldCommit)))
        #expect(result.outcome == .needsProbe)
        #expect(result.reason.contains("build-probe"))
    }

    @Test func freshConclusiveProbeLetsTheRecordBump() {
        let record = makeRecord(platforms: [
            "visionOS": PlatformClaim(status: .unsupported, confidence: 0.9, evidence: [buildAnchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record, newDecls: [filterDecl(), urlDecl()],
                                                 buildVerdicts: verdict(.failed, commit: newCommit)))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
    }

    @Test func freshProbeContradictingTheClaimIsTruthChanged() {
        // The package now compiles on visionOS — 'unsupported' no longer
        // grounds (V04): the truth changed out from under the record.
        let record = makeRecord(platforms: [
            "visionOS": PlatformClaim(status: .unsupported, confidence: 0.9, evidence: [buildAnchor]),
        ])
        let result = RecheckEngine.recheck(input(record: record, newDecls: [filterDecl(), urlDecl()],
                                                 buildVerdicts: verdict(.built, commit: newCommit)))
        #expect(result.outcome == .truthChanged)
        #expect(result.diagnostics.contains { $0.rule == "V04" })
    }

    // MARK: - Ceiling shifts (V05 through re-validation)

    @Test func binaryTargetsAppearingCapsConfidence_truthChanged() {
        // 0.9 was fine at the old tag; the new tag ships an xcframework and
        // the Krisp lesson caps it at 0.8 — that's a truth change, not a bump.
        let result = RecheckEngine.recheck(input(record: liveKitRecord(),
                                                 newDecls: [filterDecl(), urlDecl()],
                                                 newBinaryTargets: true))
        #expect(result.outcome == .truthChanged)
        #expect(result.diagnostics.contains { $0.rule == "V05" && $0.message.contains("binary") })
    }

    @Test func binaryTargetsAppearingUnderTheCapStillBumps() {
        let humble = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.75, evidence: [symbolAnchor]),
            "macOS": PlatformClaim(status: .unsupported, confidence: 0.75, evidence: [guardAnchor]),
        ])
        let result = RecheckEngine.recheck(input(record: humble,
                                                 newDecls: [filterDecl(), urlDecl()],
                                                 newBinaryTargets: true))
        #expect(result.outcome == .stillTrue, "\(result.reason)")
    }

    // MARK: - Report plumbing

    @Test func reportSummariesCountRecordsAndAppliedPackages() {
        let inp = input(record: liveKitRecord(), newDecls: [filterDecl(), urlDecl()])
        let rechecked = RecheckEngine.recheck(inp)
        let entry = RecheckReport.PackageEntry(
            canonicalURL: home, name: "LiveKit", status: "new-tag",
            pinnedTag: "2.15.1", pinnedCommit: oldCommit,
            latestTag: newTag, latestCommit: newCommit,
            applied: true, recordFiles: ["data/records/audio/livekit__client-sdk-swift.json"],
            records: [rechecked])
        let upToDate = RecheckReport.PackageEntry(
            canonicalURL: "https://github.com/a/b", name: "b", status: "up-to-date",
            records: [rechecked])
        let skipped = RecheckReport.PackageEntry(
            canonicalURL: "https://developer.apple.com/documentation/avfaudio",
            name: "AVFAudio", status: "skipped", skipReason: "first-party")
        let report = RecheckReport(generatedAt: "2026-07-05T00:00:00Z", apply: true,
                                   packages: [entry, upToDate, skipped])
        #expect(report.summary.stillTrue == 1)
        #expect(report.summary.upToDate == 1)
        #expect(report.summary.skipped == 1)
        #expect(report.summary.applied == 1)
        // Sorted by canonical URL for deterministic output.
        #expect(report.packages.first?.canonicalURL == "https://developer.apple.com/documentation/avfaudio")

        // Round-trips as JSON — the cron/PR/feed slices consume this.
        let data = try! JSONEncoder().encode(report)
        let decoded = try! JSONDecoder().decode(RecheckReport.self, from: data)
        #expect(decoded.summary.stillTrue == 1)
        #expect(decoded.packages.count == 3)
    }
}
