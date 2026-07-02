import Testing
@testable import SwiftServeScan

@Suite("Attribution & rollup")
struct AttributionTests {

    func finding(_ symbol: String, _ sev: Severity, origin: Origin) -> Finding {
        Finding(symbol: symbol, rawSymbol: "_" + symbol, symbolKind: .importedSymbol, matchType: .exact,
                matchedPattern: symbol, framework: "x", severity: sev, explanation: "x",
                rejectionCode: nil, alternative: nil, reference: nil, origin: origin)
    }

    @Test("An artifact maps to its dependency identity + version")
    func attributesToDependency() {
        let path = "/dd/SourcePackages/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework"
        let map = ArtifactMap([
            ArtifactMapping(artifactPath: path,
                            origin: Origin(kind: .dependency, dependency: "webrtc-xcframework",
                                           version: "137.7151.12", artifact: "LiveKitWebRTC.xcframework"))
        ])
        let o = Attributor.origin(forArtifact: path, in: map)
        #expect(o.kind == .dependency)
        #expect(o.dependency == "webrtc-xcframework")
        #expect(o.version == "137.7151.12")
    }

    @Test("An unmapped artifact is unattributed, never dropped")
    func unattributed() {
        let o = Attributor.origin(forArtifact: "/some/mystery/Thing.framework/Thing", in: ArtifactMap([]))
        #expect(o.kind == .unattributed)
        #expect(o.artifact == "Thing")
    }

    @Test("Rollup: declared units appear even with 0 findings; first-party vs dependency split is correct")
    func rollup() {
        let units = [
            ScanUnit(kind: .firstParty, identity: nil, version: nil, status: .scanned, artifacts: ["Draft"]),
            ScanUnit(kind: .dependency, identity: "webrtc-xcframework", version: "137.7151.12", status: .scanned, artifacts: ["LiveKitWebRTC.xcframework"]),
            ScanUnit(kind: .dependency, identity: "kingfisher", version: "8.8.1", status: .sourceOnly),
            ScanUnit(kind: .dependency, identity: "some-sdk", version: "3.1.0", status: .notBuilt),
        ]
        let findings = [
            finding("MGCopyAnswer", .high, origin: Origin(kind: .dependency, dependency: "webrtc-xcframework", version: "137.7151.12", artifact: "LiveKitWebRTC.xcframework")),
            finding("setOrientation", .low, origin: Origin(kind: .firstParty, artifact: "Draft")),
        ]
        let rollups = DependencyRollup.build(units: units, findings: findings)

        #expect(rollups.count == 4)
        #expect(rollups.first?.kind == .firstParty)             // your code first
        #expect(rollups.first?.findingCount == 1)

        let webrtc = try! #require(rollups.first { $0.identity == "webrtc-xcframework" })
        #expect(webrtc.high == 1)
        #expect(webrtc.version == "137.7151.12")

        let kf = try! #require(rollups.first { $0.identity == "kingfisher" })
        #expect(kf.status == .sourceOnly)
        #expect(kf.findingCount == 0)

        let sdk = try! #require(rollups.first { $0.identity == "some-sdk" })
        #expect(sdk.status == .notBuilt)
    }

    @Test("A finding with no declared unit still gets an unattributed rollup")
    func undeclaredFindingBucketed() {
        let findings = [finding("Mystery", .high, origin: Origin(kind: .unattributed, artifact: "Thing"))]
        let rollups = DependencyRollup.build(units: [], findings: findings)
        #expect(rollups.contains { $0.kind == .unattributed && $0.findingCount == 1 })
    }
}
