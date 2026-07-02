import Foundation
import Testing
@testable import SwiftServeCapability

/// The validator is what makes LLM labeling safe to trust — so every rule
/// gets an accept AND a reject case, built around the LiveKit shape. The
/// crown jewel: rejecting the exact hallucination that founded this product
/// (claiming macOS support for an iOS-only capability).
@Suite struct RecordValidatorTests {

    // MARK: - A LiveKit-shaped world, constructed as pure data

    private let home = "https://github.com/livekit/client-sdk-swift"
    private let companion = "https://github.com/livekit/swift-krisp-noise-filter"

    private func makeSurfaces(binaryTargets: Bool = false) -> [String: PackageSurface] {
        let filterDecl = SurfaceDecl(
            name: "RoomOptions.noiseCancellationFilter", kind: .property,
            signature: "var noiseCancellationFilter: AudioFilter?",
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 214),
            condition: .os("iOS"), rawCondition: "os(iOS)",
            availability: [],
            resolvedPlatforms: [
                "iOS": .present, "macOS": .absent, "watchOS": .absent, "tvOS": .absent,
                "visionOS": .absent, "macCatalyst": .present, "linux": .absent,
            ],
            docSummary: "Enables Krisp-powered noise cancellation.", hasMacroAttributes: false)

        let urlDecl = SurfaceDecl(
            name: "RoomOptions.url", kind: .property, signature: "var url: String",
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 30),
            condition: nil, rawCondition: nil, availability: [],
            resolvedPlatforms: Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0.rawValue, PlatformPresence.present) }),
            docSummary: nil, hasMacroAttributes: false)

        let debugDecl = SurfaceDecl(
            name: "RoomOptions.debugMode", kind: .property, signature: "var debugMode: Bool",
            location: SurfaceLocation(file: "Sources/LiveKit/Types/Options.swift", line: 300),
            condition: .flag("LK_DEBUG"), rawCondition: "LK_DEBUG", availability: [],
            resolvedPlatforms: Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0.rawValue, PlatformPresence.conditional("LK_DEBUG")) }),
            docSummary: nil, hasMacroAttributes: false)

        let homeSurface = PackageSurface(
            package: PackageProvenance(canonicalURL: home, name: "client-sdk-swift", tag: "2.15.1", commit: "abc123"),
            manifestPlatforms: [ManifestPlatform(platform: "iOS", minVersion: "13")],
            decls: [filterDecl, urlDecl, debugDecl],
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: 3, parseFailures: 0,
                                manifestUnparsed: false, hasBinaryTargets: false))

        let krispDecl = SurfaceDecl(
            name: "LiveKitKrispNoiseFilter", kind: .class, signature: nil,
            location: SurfaceLocation(file: "Sources/LiveKitKrispNoiseFilter/LiveKitKrispNoiseFilter.swift", line: 10),
            condition: nil, rawCondition: nil, availability: [],
            resolvedPlatforms: Dictionary(uniqueKeysWithValues: Platform.allCases.map { ($0.rawValue, PlatformPresence.present) }),
            docSummary: nil, hasMacroAttributes: false)

        let companionSurface = PackageSurface(
            package: PackageProvenance(canonicalURL: companion, name: "swift-krisp-noise-filter", tag: "0.0.8", commit: "def456"),
            manifestPlatforms: [],
            decls: [krispDecl],
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: 1, parseFailures: 0,
                                manifestUnparsed: false, hasBinaryTargets: binaryTargets))

        return [home: homeSurface, companion: companionSurface]
    }

    private let taxonomy = Taxonomy(domain: "audio", capabilities: [
        .init(id: "audio.noise-cancellation", label: "Noise cancellation"),
    ])

    private func makeRecord(capabilityID: String = "audio.noise-cancellation",
                            commit: String = "abc123",
                            platforms: [String: PlatformClaim]) -> CapabilityRecord {
        CapabilityRecord(
            package: RecordPackage(canonicalURL: home, name: "LiveKit",
                                   aliases: ["LiveKitClient"], version: "2.15.1",
                                   commit: commit, surfaceDigest: "fnv1a64:0"),
            capability: CapabilityRef(id: capabilityID, label: "Noise cancellation"),
            platforms: platforms,
            labeledBy: "test", labeledAt: "2026-07-02T00:00:00Z")
    }

    private let goodSymbolAnchor = EvidenceAnchor(
        kind: .symbol, symbol: "RoomOptions.noiseCancellationFilter",
        file: "Sources/LiveKit/Types/Options.swift", line: 214, condition: "os(iOS)")

    private let goodGuardAnchor = EvidenceAnchor(
        kind: .guard, symbol: "RoomOptions.noiseCancellationFilter",
        file: "Sources/LiveKit/Types/Options.swift", line: 214, condition: "os(iOS)")

    private func validate(_ record: CapabilityRecord,
                          binaryTargets: Bool = false) -> RecordValidator.ValidationResult {
        RecordValidator.validate(record, surfaces: makeSurfaces(binaryTargets: binaryTargets), taxonomy: taxonomy)
    }

    // MARK: - The acceptance pair: real truth accepted, the hallucination rejected

    @Test func acceptsTheTrueLiveKitRecord() {
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [goodSymbolAnchor]),
            "macOS": PlatformClaim(status: .unsupported, confidence: 0.85, evidence: [goodGuardAnchor]),
        ])
        let result = validate(record)
        #expect(result.isAccepted, "\(result.errors)")
        // W01 nudges toward full platform coverage but never blocks.
        #expect(result.diagnostics.contains { $0.rule == "W01" })
    }

    @Test func rejectsTheFoundingHallucination_macOSSupported() {
        // The exact claim an ungrounded model would make — and days were lost to.
        let record = makeRecord(platforms: [
            "macOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [goodSymbolAnchor]),
        ])
        let result = validate(record)
        #expect(!result.isAccepted)
        #expect(result.errors.contains { $0.rule == "V03" })
    }

    // MARK: - Rule-by-rule rejects

    @Test func v01RejectsUnknownCapabilityID() {
        let record = makeRecord(capabilityID: "audio.made-up", platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [goodSymbolAnchor]),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V01" })
    }

    @Test func v02RejectsHallucinatedSymbol() {
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "RoomOptions.enableKrispMagic",
                                    file: "Sources/LiveKit/Types/Options.swift", line: 214)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [anchor]),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V02" && $0.message.contains("hallucinated") })
    }

    @Test func v02RejectsWrongLine() {
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "RoomOptions.noiseCancellationFilter",
                                    file: "Sources/LiveKit/Types/Options.swift", line: 999)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [anchor]),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V02" })
    }

    @Test func v03RequiresConditionalStatusWhenEvidenceIsConditional() {
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "RoomOptions.debugMode",
                                    file: "Sources/LiveKit/Types/Options.swift", line: 300)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.5, evidence: [anchor]),
        ])
        let result = validate(record)
        #expect(result.errors.contains { $0.rule == "V03" && $0.message.contains("conditional") })
    }

    @Test func v04RejectsUnsupportedWithoutAProvenFence() {
        // Symbol absence is not evidence of absence.
        let record = makeRecord(platforms: [
            "watchOS": PlatformClaim(status: .unsupported, confidence: 0.5,
                                     evidence: [EvidenceAnchor(kind: .manifestPlatforms,
                                                               note: "manifest lists iOS only")]),
        ])
        let result = validate(record)
        #expect(result.errors.contains { $0.rule == "V04" })
    }

    @Test func v05CapsWeakEvidenceAtUnknownPoint3() {
        let readmeOnly = makeRecord(platforms: [
            "macOS": PlatformClaim(status: .supported, confidence: 0.5,
                                   evidence: [EvidenceAnchor(kind: .readme, note: "README says macOS works")]),
        ])
        let result = validate(readmeOnly)
        #expect(result.errors.contains { $0.rule == "V05" && $0.message.contains("unknown") })

        let honest = makeRecord(platforms: [
            "macOS": PlatformClaim(status: .unknown, confidence: 0.3,
                                   evidence: [EvidenceAnchor(kind: .readme, note: "README says macOS works")]),
        ])
        #expect(validate(honest).isAccepted)
    }

    @Test func v05CapsAbsoluteConfidence() {
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.99, evidence: [goodSymbolAnchor]),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V05" })
    }

    @Test func v05BinaryTargetsCapConfidence_theKrispLesson() {
        // Anchor on the companion package, which ships an xcframework: the
        // real fence may live in the binary, so confidence caps at 0.8.
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "LiveKitKrispNoiseFilter",
                                    file: "Sources/LiveKitKrispNoiseFilter/LiveKitKrispNoiseFilter.swift",
                                    line: 10, package: companion)
        let tooConfident = makeRecord(platforms: [
            "macOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [anchor]),
        ])
        let result = validate(tooConfident, binaryTargets: true)
        #expect(result.errors.contains { $0.rule == "V05" && $0.message.contains("binary") })

        let humble = makeRecord(platforms: [
            "macOS": PlatformClaim(status: .supported, confidence: 0.75, evidence: [anchor]),
        ])
        #expect(validate(humble, binaryTargets: true).isAccepted)
    }

    @Test func v06RejectsCommitDrift() {
        let record = makeRecord(commit: "stale00", platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [goodSymbolAnchor]),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V06" })
    }

    @Test func v07RejectsMadeUpPlatformKeys() {
        let record = makeRecord(platforms: [
            "windows": PlatformClaim(status: .unknown, confidence: 0.0, evidence: []),
        ])
        #expect(validate(record).errors.contains { $0.rule == "V07" })
    }

    @Test func duplicateDeclNamesDisambiguateByFileAndLine() {
        // The AudioKit/Waveform shape: two same-named types split by
        // os(macOS)/!os(macOS). The anchor's file+line picks the exact one.
        let macSide = SurfaceDecl(
            name: "Waveform", kind: .struct, signature: nil,
            location: SurfaceLocation(file: "Sources/Waveform/Waveform.swift", line: 9),
            condition: .os("macOS"), rawCondition: "os(macOS)", availability: [],
            resolvedPlatforms: ["iOS": .absent, "macOS": .present],
            docSummary: nil, hasMacroAttributes: false)
        let otherSide = SurfaceDecl(
            name: "Waveform", kind: .struct, signature: nil,
            location: SurfaceLocation(file: "Sources/Waveform/Waveform.swift", line: 68),
            condition: .not(.os("macOS")), rawCondition: "!os(macOS)", availability: [],
            resolvedPlatforms: ["iOS": .present, "macOS": .absent],
            docSummary: nil, hasMacroAttributes: false)
        let surface = PackageSurface(
            package: PackageProvenance(canonicalURL: home, name: "x", tag: "1.0.0", commit: "abc123"),
            manifestPlatforms: [], decls: [macSide, otherSide],
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: 2, parseFailures: 0, manifestUnparsed: false))

        func record(line: Int, platform: String) -> CapabilityRecord {
            makeRecord(platforms: [platform: PlatformClaim(
                status: .supported, confidence: 0.8,
                evidence: [EvidenceAnchor(kind: .symbol, symbol: "Waveform",
                                          file: "Sources/Waveform/Waveform.swift", line: line)])])
        }
        let taxonomy = Taxonomy(domain: "audio", capabilities: [
            .init(id: "audio.noise-cancellation", label: "Noise cancellation"),
        ])
        // Anchoring the iOS claim on the !os(macOS) decl (line 68) works…
        #expect(RecordValidator.validate(record(line: 68, platform: "iOS"),
                                         surfaces: [home: surface], taxonomy: taxonomy).isAccepted)
        // …anchoring it on the macOS-side decl (line 9) is rejected by V03…
        #expect(!RecordValidator.validate(record(line: 9, platform: "iOS"),
                                          surfaces: [home: surface], taxonomy: taxonomy).isAccepted)
        // …and a line matching neither decl dies with the ambiguity error.
        let neither = RecordValidator.validate(record(line: 40, platform: "iOS"),
                                               surfaces: [home: surface], taxonomy: taxonomy)
        #expect(neither.errors.contains { $0.rule == "V02" && $0.message.contains("2 declarations") })
    }

    @Test func companionAnchorsResolveAgainstTheCompanionSurface() {
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "LiveKitKrispNoiseFilter",
                                    file: "Sources/LiveKitKrispNoiseFilter/LiveKitKrispNoiseFilter.swift",
                                    line: 10, package: companion)
        let record = makeRecord(platforms: [
            "iOS": PlatformClaim(status: .supported, confidence: 0.75, evidence: [anchor, goodSymbolAnchor]),
        ])
        #expect(validate(record, binaryTargets: true).isAccepted)
    }
}

/// The digest keeps labeling bundles small without ever weakening validation.
@Suite struct SurfaceDigestTests {

    @Test func fencedDeclsComeFirstAndTruncationIsHonest() {
        let fenced = SurfaceDecl(
            name: "Z.fenced", kind: .property, signature: nil,
            location: SurfaceLocation(file: "a.swift", line: 1),
            condition: .os("iOS"), rawCondition: "os(iOS)", availability: [],
            resolvedPlatforms: ["iOS": .present, "macOS": .absent],
            docSummary: nil, hasMacroAttributes: false)
        let plain = (0..<10).map { i in
            SurfaceDecl(name: "A.plain\(i)", kind: .function, signature: nil,
                        location: SurfaceLocation(file: "b.swift", line: i + 1),
                        condition: nil, rawCondition: nil, availability: [],
                        resolvedPlatforms: ["iOS": .present], docSummary: nil, hasMacroAttributes: false)
        }
        let surface = PackageSurface(
            package: PackageProvenance(canonicalURL: "u", name: "n", tag: "1.0.0", commit: "c"),
            manifestPlatforms: [], decls: plain + [fenced],
            stats: SurfaceStats(swiftFiles: 2, objcFiles: 0, declCount: 11, parseFailures: 0, manifestUnparsed: false))

        let digest = SurfaceDigest.build(from: surface, limit: 5)
        #expect(digest.decls.first?.name == "Z.fenced")           // fenced beats source order
        #expect(digest.decls.first?.gaps?["macOS"] == "absent")   // the signal survives compaction
        #expect(digest.truncated)
        #expect(digest.declCount == 5)
        #expect(digest.totalDecls == 11)
    }

    @Test func synthesizedNoiseIsDropped() {
        let noise = SurfaceDecl(name: "A.hashValue", kind: .property, signature: nil,
                                location: SurfaceLocation(file: "a.swift", line: 1),
                                condition: nil, rawCondition: nil, availability: [],
                                resolvedPlatforms: nil, docSummary: nil, hasMacroAttributes: false)
        let surface = PackageSurface(
            package: PackageProvenance(canonicalURL: "u", name: "n", tag: nil, commit: nil),
            manifestPlatforms: [], decls: [noise],
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: 1, parseFailures: 0, manifestUnparsed: false))
        #expect(SurfaceDigest.build(from: surface).decls.isEmpty)
    }
}
