import Foundation
import Testing
@testable import SwiftServeCapability

/// The resolver is the shared identity rule for "which decl does this anchor
/// name" — validator and recheck both stand on it, so every failure mode gets
/// its own case.
@Suite struct AnchorResolverTests {

    private let home = "https://github.com/livekit/client-sdk-swift"

    private func decl(_ name: String, file: String, line: Int) -> SurfaceDecl {
        SurfaceDecl(name: name, kind: .property, signature: nil,
                    location: SurfaceLocation(file: file, line: line),
                    condition: nil, rawCondition: nil, availability: [],
                    resolvedPlatforms: ["iOS": .present], docSummary: nil,
                    hasMacroAttributes: false)
    }

    private func surface(_ decls: [SurfaceDecl]) -> [String: PackageSurface] {
        [home: PackageSurface(
            package: PackageProvenance(canonicalURL: home, name: "x", tag: "1.0.0", commit: "abc123"),
            manifestPlatforms: [], decls: decls,
            stats: SurfaceStats(swiftFiles: 1, objcFiles: 0, declCount: decls.count,
                                parseFailures: 0, manifestUnparsed: false))]
    }

    @Test func exactHitAmongDuplicatesResolvesByFileAndLine() {
        let surfaces = surface([decl("Waveform", file: "a.swift", line: 9),
                                decl("Waveform", file: "a.swift", line: 68)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Waveform", file: "a.swift", line: 68)
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surfaces)
        #expect(try! result.get().location.line == 68)
    }

    @Test func singleCandidateResolvesWithoutFileAndLine() {
        let surfaces = surface([decl("Sound.play", file: "Sound.swift", line: 40)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Sound.play")
        #expect((try? AnchorResolver.resolve(anchor, home: home, surfaces: surfaces).get()) != nil)
    }

    @Test func weakKindsAreNotResolvable() {
        let surfaces = surface([decl("Sound", file: "Sound.swift", line: 1)])
        for kind in [EvidenceKind.readme, .manifestPlatforms, .buildVerdict] {
            let result = AnchorResolver.resolve(EvidenceAnchor(kind: kind), home: home, surfaces: surfaces)
            #expect(result == .failure(.notResolvable))
        }
    }

    @Test func missingSurfaceFails() {
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Sound",
                                    package: "https://github.com/other/pkg")
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surface([]))
        #expect(result == .failure(.noSurface("https://github.com/other/pkg")))
    }

    @Test func symbolKindWithoutASymbolFails() {
        let result = AnchorResolver.resolve(EvidenceAnchor(kind: .symbol), home: home,
                                            surfaces: surface([]))
        #expect(result == .failure(.noSymbol))
    }

    @Test func unknownSymbolFails() {
        let surfaces = surface([decl("Sound", file: "Sound.swift", line: 1)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Sound.magic")
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surfaces)
        #expect(result == .failure(.symbolMissing("Sound.magic")))
    }

    @Test func duplicatesWithNoExactMatchAreAmbiguous() {
        let surfaces = surface([decl("Waveform", file: "a.swift", line: 9),
                                decl("Waveform", file: "a.swift", line: 68)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Waveform", file: "a.swift", line: 40)
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surfaces)
        #expect(result == .failure(.ambiguous(symbol: "Waveform", count: 2)))
    }

    @Test func uniqueCandidateInAnotherFileIsAFileMismatch() {
        let surfaces = surface([decl("Sound", file: "Sources/New.swift", line: 5)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Sound",
                                    file: "Sources/Old.swift", line: 5)
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surfaces)
        #expect(result == .failure(.fileMismatch(anchor: "Sources/Old.swift",
                                                 surface: "Sources/New.swift")))
    }

    @Test func uniqueCandidateAtAnotherLineIsALineMismatch() {
        let surfaces = surface([decl("Sound", file: "Sound.swift", line: 50)])
        let anchor = EvidenceAnchor(kind: .symbol, symbol: "Sound", file: "Sound.swift", line: 40)
        let result = AnchorResolver.resolve(anchor, home: home, surfaces: surfaces)
        #expect(result == .failure(.lineMismatch(anchor: 40, surface: 50)))
    }
}
