import Testing
@testable import SwiftServeSurface
import SwiftServeCapability

/// Acceptance test #1 — the founding incident, as a fixture. The pipeline
/// must rediscover from source alone that LiveKit-style noise cancellation
/// is iOS-only: a healthy package, a real feature, silently absent on macOS.
/// The snippets are reduced from the real shape of the LiveKit SDK (an
/// iOS-guarded member on an options struct) and its Krisp companion package
/// (a filter class fenced by os + canImport).
@Suite struct LiveKitFixtureTests {

    private let modules = ModulePlatformTable(version: 1, modules: [
        "UIKit": ["iOS", "tvOS", "visionOS", "macCatalyst"],
        "AVFAudio": ["iOS", "macOS", "tvOS", "watchOS", "visionOS", "macCatalyst"],
    ])

    private func resolvedDecls(_ source: String) -> [SurfaceDecl] {
        SurfaceExtractor.decls(in: source, file: "Sources/LiveKit/Types/Options.swift").map { decl in
            decl.resolving(PlatformResolver.resolve(
                condition: decl.condition, availability: decl.availability, modules: modules))
        }
    }

    @Test func noiseCancellationMemberIsPresentOniOSAbsentOnMacOS() {
        let decls = resolvedDecls("""
        public struct RoomOptions {
            public var url: String = ""
            #if os(iOS)
            /// Enables Krisp-powered noise cancellation for the local mic track.
            public var noiseCancellationFilter: AudioFilter?
            #endif
        }
        """)

        let filter = decls.first { $0.name == "RoomOptions.noiseCancellationFilter" }!
        #expect(filter.resolvedPlatforms?["iOS"] == .present)
        #expect(filter.resolvedPlatforms?["macOS"] == .absent)       // the days-lost fact
        #expect(filter.resolvedPlatforms?["watchOS"] == .absent)
        #expect(filter.rawCondition == "os(iOS)")                    // the receipt
        #expect(filter.location.file == "Sources/LiveKit/Types/Options.swift")

        // The unguarded member stays present everywhere — no over-fencing.
        let url = decls.first { $0.name == "RoomOptions.url" }!
        #expect(url.resolvedPlatforms?["macOS"] == .present)
    }

    @Test func companionKrispFilterShapeResolvesTheSameWay() {
        let decls = resolvedDecls("""
        #if os(iOS) && canImport(AVFAudio)
        public class KrispNoiseFilter {
            public init() {}
            public func process(buffer: AVAudioPCMBuffer) {}
        }
        #endif
        """)

        let filter = decls.first { $0.name == "KrispNoiseFilter" }!
        #expect(filter.resolvedPlatforms?["iOS"] == .present)
        #expect(filter.resolvedPlatforms?["macOS"] == .absent)
        #expect(filter.rawCondition == "os(iOS) && canImport(AVFAudio)")
    }

    @Test func availabilityFencedVariantResolvesAbsentToo() {
        // Same truth expressed the other way packages write it.
        let decls = resolvedDecls("""
        @available(macOS, unavailable)
        public class NoiseProcessor {
            public func enable() {}
        }
        """)
        let processor = decls.first { $0.name == "NoiseProcessor" }!
        #expect(processor.resolvedPlatforms?["macOS"] == .absent)
        #expect(processor.resolvedPlatforms?["iOS"] == .present)
        // Members inherit the fence through the availability stack.
        let enable = decls.first { $0.name == "NoiseProcessor.enable" }!
        #expect(enable.resolvedPlatforms?["macOS"] == .absent)
    }
}

/// Package.swift `platforms:` reading — floors, never fences.
@Suite struct ManifestPlatformsTests {

    @Test func normalManifest() {
        let platforms = ManifestPlatforms.extract(from: """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "LiveKit",
            platforms: [.iOS(.v13), .macOS(.v10_15), .custom("openbsd", versionString: "7.0")],
            targets: []
        )
        """)
        #expect(platforms == [
            ManifestPlatform(platform: "iOS", minVersion: "13"),
            ManifestPlatform(platform: "macOS", minVersion: "10.15"),
            ManifestPlatform(platform: "openbsd", minVersion: "7.0"),
        ])
    }

    @Test func stringVersionForm() {
        let platforms = ManifestPlatforms.extract(from: """
        let package = Package(name: "X", platforms: [.macOS("10.15")], targets: [])
        """)
        #expect(platforms == [ManifestPlatform(platform: "macOS", minVersion: "10.15")])
    }

    @Test func missingPlatformsMeansDefaultFloorsNotUnparsed() {
        let platforms = ManifestPlatforms.extract(from: """
        let package = Package(name: "X", targets: [])
        """)
        #expect(platforms == [])
    }

    @Test func programmaticManifestIsHonestlyUnparsed() {
        #expect(ManifestPlatforms.extract(from: "let x = 1") == nil)
        #expect(ManifestPlatforms.extract(from: """
        let plats: [SupportedPlatform] = makePlatforms()
        let package = Package(name: "X", platforms: plats, targets: [])
        """) == nil)
    }

    @Test func binaryTargetsAreFlaggedAsABlindSpot() {
        // The real Krisp shape: unguarded Swift over a binaryTarget — the
        // fence lives in the binary, so the surface must say so.
        let manifest = """
        let package = Package(name: "LiveKitKrispNoiseFilter", targets: [
            .binaryTarget(name: "KrispNoiseFilter", url: "https://x/y.zip", checksum: "abc"),
            .target(name: "LiveKitKrispNoiseFilter", dependencies: ["KrispNoiseFilter"]),
        ])
        """
        #expect(ManifestPlatforms.hasBinaryTargets(in: manifest))
        #expect(!ManifestPlatforms.hasBinaryTargets(in: "let package = Package(name: \"X\", targets: [.target(name: \"Y\")])"))
    }
}
