import Foundation
import Testing
@testable import SwiftServeSurface
import SwiftServeCapability

/// The first-party channel: symbol graphs parse into surface decls, and the
/// per-SDK merge decides platform presence by membership + @available
/// overlays — built around the AVFAudio shape (ObjC-imported API the
/// swiftinterface overlay misses).
@Suite struct SymbolGraphTests {

    private let graph = """
    {
      "module": { "name": "AVFAudio" },
      "symbols": [
        {
          "kind": { "identifier": "swift.class" },
          "names": { "title": "AVAudioEngine",
                     "subHeading": [{ "kind": "keyword", "spelling": "class" },
                                    { "kind": "text", "spelling": " " },
                                    { "kind": "identifier", "spelling": "AVAudioEngine" }] },
          "pathComponents": ["AVAudioEngine"],
          "docComment": { "lines": [{ "text": "An object that manages a graph of audio nodes." }] },
          "availability": [
            { "domain": "iOS", "introduced": { "major": 8, "minor": 0 } },
            { "domain": "visionOS", "introduced": { "major": 1, "minor": 0 } }
          ]
        },
        {
          "kind": { "identifier": "swift.method" },
          "names": { "subHeading": [{ "kind": "keyword", "spelling": "func" },
                                    { "kind": "text", "spelling": " start() throws" }] },
          "pathComponents": ["AVAudioEngine", "start()"],
          "availability": [{ "domain": "watchOS", "isUnconditionallyUnavailable": true }]
        },
        {
          "kind": { "identifier": "swift.macro" },
          "names": { "subHeading": [] },
          "pathComponents": ["NotAnchorMaterial"]
        }
      ]
    }
    """

    @Test func parsesSymbolsIntoDecls() throws {
        let decls = try SymbolGraphParser.decls(from: Data(graph.utf8), file: "symbolgraph/arm64-apple-xros26.5/AVFAudio.symbols.json")
        // The macro is dropped; the class and method survive, sorted by name.
        #expect(decls.map(\.name) == ["AVAudioEngine", "AVAudioEngine.start()"])
        let engine = decls[0]
        #expect(engine.kind == .class)
        #expect(engine.signature == "class AVAudioEngine")
        #expect(engine.docSummary == "An object that manages a graph of audio nodes.")
        #expect(engine.availability.contains {
            $0.platform == "visionOS" && $0.introduced == "1.0" && !$0.unavailable
        })
        // Ordinal lines: stable disambiguators in a location-less format.
        #expect(decls.map(\.location.line) == [1, 2])
        #expect(decls[1].availability.contains { $0.platform == "watchOS" && $0.unavailable })
    }

    @Test func mergeDecidesPresenceBySDKMembershipAndAvailability() throws {
        let decls = try SymbolGraphParser.decls(from: Data(graph.utf8), file: "symbolgraph/arm64-apple-xros26.5/AVFAudio.symbols.json")
        // In the visionOS + iOS SDKs; absent from the rest by membership.
        let merged = SDKSurfaceMerger.merge(perPlatform: [.visionOS: decls, .iOS: decls])
        #expect(merged.count == 2)
        let engine = try #require(merged.first { $0.name == "AVAudioEngine" })
        #expect(engine.resolvedPlatforms?["visionOS"] == .present)
        #expect(engine.resolvedPlatforms?["iOS"] == .present)
        #expect(engine.resolvedPlatforms?["macCatalyst"] == .present)   // rides iOS
        #expect(engine.resolvedPlatforms?["macOS"] == .absent)          // not in that SDK's parse
        #expect(engine.resolvedPlatforms?["linux"] == .absent)          // no Apple SDK ships there
        // start() is fenced off watchOS by @available even where membership exists.
        let start = try #require(merged.first { $0.name == "AVAudioEngine.start()" })
        #expect(start.resolvedPlatforms?["watchOS"] == .absent)
    }

    @Test func mergePrefersTheVisionOSInterfaceAsPrimary() throws {
        let visionDecls = try SymbolGraphParser.decls(from: Data(graph.utf8), file: "symbolgraph/arm64-apple-xros26.5/AVFAudio.symbols.json")
        let macDecls = try SymbolGraphParser.decls(from: Data(graph.utf8), file: "symbolgraph/arm64-apple-macosx26.5/AVFAudio.symbols.json")
        let merged = SDKSurfaceMerger.merge(perPlatform: [.macOS: macDecls, .visionOS: visionDecls])
        #expect(merged.allSatisfy { $0.location.file.contains("xros") })
    }
}
