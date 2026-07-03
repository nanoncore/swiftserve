import Foundation
import Testing
@testable import SwiftServeSite
import SwiftServeCapability

@Suite struct OnPlatformPageTests {

    /// Four records covering every pivot state: a first-party framework
    /// (supported, with a floor), a third-party that serves visionOS, one
    /// fenced by a build verdict (but fine on iOS), and one honest unknown.
    private func makeSite(basePath: String = "") -> Site {
        let taxonomy = Taxonomy(domain: "audio", capabilities: [
            .init(id: "audio.playback", label: "Audio playback"),
            .init(id: "audio.recording", label: "Audio recording"),
            .init(id: "midi.io", label: "MIDI I/O"),
        ])

        let builtIn = CapabilityRecord(
            package: RecordPackage(canonicalURL: "https://developer.apple.com/documentation/avfaudio",
                                   name: "AVFAudio", aliases: [], version: "Xcode 26.6",
                                   commit: "17F113", surfaceDigest: "fnv1a64:0", firstParty: true),
            capability: CapabilityRef(id: "audio.playback", label: "Audio playback"),
            platforms: [
                "visionOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [
                    EvidenceAnchor(kind: .symbol, symbol: "AVAudioPlayer",
                                   file: "symbolgraph/arm64-apple-xros26.5/AVFAudio.symbols.json",
                                   line: 10, note: "visionOS 1.0+"),
                ]),
            ],
            labeledBy: "test", labeledAt: "2026-07-03T00:00:00Z")

        let serves = CapabilityRecord(
            package: RecordPackage(canonicalURL: "https://github.com/audiokit/audiokit",
                                   name: "AudioKit", aliases: [], version: "5.6.5",
                                   commit: "aaaa1111", surfaceDigest: "fnv1a64:1"),
            capability: CapabilityRef(id: "audio.playback", label: "Audio playback"),
            platforms: [
                "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: []),
                "visionOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: [
                    EvidenceAnchor(kind: .buildVerdict, note: "compiles for visionOS"),
                ]),
            ],
            labeledBy: "test", labeledAt: "2026-07-03T00:00:00Z")

        let fenced = CapabilityRecord(
            package: RecordPackage(canonicalURL: "https://github.com/jaredsinclair/sodes-audio-example",
                                   name: "FencedKit", aliases: [], version: "1.2.3",
                                   commit: "bbbb2222", surfaceDigest: "fnv1a64:2"),
            capability: CapabilityRef(id: "audio.recording", label: "Audio recording"),
            platforms: [
                "iOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: []),
                "macOS": PlatformClaim(status: .supported, confidence: 0.9, evidence: []),
                "visionOS": PlatformClaim(status: .unsupported, confidence: 0.9, evidence: [
                    EvidenceAnchor(kind: .buildVerdict,
                                   note: "does not compile for visionOS (Xcode 26.6): error: 'statusBarOrientation' is unavailable in visionOS"),
                ]),
            ],
            labeledBy: "test", labeledAt: "2026-07-03T00:00:00Z")

        let unknown = CapabilityRecord(
            package: RecordPackage(canonicalURL: "https://github.com/adamnemecek/webmidikit",
                                   name: "WebMIDIKit", aliases: [], version: "0.9.0",
                                   commit: "cccc3333", surfaceDigest: "fnv1a64:3"),
            capability: CapabilityRef(id: "midi.io", label: "MIDI I/O"),
            platforms: [
                "visionOS": PlatformClaim(status: .unknown, confidence: 0.25, evidence: [
                    EvidenceAnchor(kind: .manifestPlatforms, note: "empty manifest"),
                ]),
            ],
            labeledBy: "test", labeledAt: "2026-07-03T00:00:00Z")

        let dataset = CapabilityDataset(taxonomy: taxonomy,
                                        records: [builtIn, serves, fenced, unknown])
        return Site(model: SiteModel(dataset: dataset), basePath: basePath)
    }

    @Test func viewDerivesCountsFromRecords() {
        let view = OnPlatformView(model: makeSite().model, platform: .visionOS)
        #expect(view.supported == 2)      // AVFAudio + AudioKit
        #expect(view.unsupported == 1)    // FencedKit
        #expect(view.unknown == 1)        // WebMIDIKit
        #expect(view.conditional == 0)
        #expect(view.recordCount == 4)
        #expect(view.packageCount == 4)
    }

    @Test func planEmitsPageAndFeed() throws {
        let paths = try SiteGenerator.plan(site: makeSite()).map(\.path)
        #expect(paths.contains("on/visionos/index.html"))
        #expect(paths.contains("api/on/visionos.json"))
    }

    @Test func pageCarriesEverySection() throws {
        let outputs = try SiteGenerator.plan(site: makeSite())
        let page = String(decoding: outputs.first { $0.path == "on/visionos/index.html" }!.bytes,
                          as: UTF8.self)

        // Headline stats, computed from the fixture.
        #expect(page.contains("The state of <em>visionOS</em>"))
        #expect(page.contains("across 4 records · 4 packages"))

        // Built into the OS: framework links to its package page, floor shown.
        #expect(page.contains("href=\"/package/avfaudio/\""))
        #expect(page.contains("visionOS 1.0+"))

        // Capability links open the truth table focused on visionOS.
        #expect(page.contains("href=\"/can/audio.playback/?on=visionOS\""))

        // The fence list: the compiler receipt verbatim, plus where it DOES work.
        #expect(page.contains("&#39;statusBarOrientation&#39; is unavailable in visionOS")
             || page.contains("'statusBarOrientation' is unavailable in visionOS"))
        #expect(page.contains("FencedKit"))
        #expect(page.contains("serves it on"))
        #expect(page.contains("<span>iOS</span><span>macOS</span>"))

        // Honest unknowns carry the reason on record.
        #expect(page.contains("WebMIDIKit"))
        #expect(page.contains("empty manifest"))

        // The one-fetch feed is linked.
        #expect(page.contains("/api/on/visionos.json"))
    }

    @Test func fenceReceiptFallsBackToSourceGuard() {
        let claim = PlatformClaim(status: .unsupported, confidence: 0.85, evidence: [
            EvidenceAnchor(kind: .guard, symbol: "SoundSession",
                           file: "Sources/Sound.swift", line: 12,
                           condition: "os(iOS) || os(tvOS)",
                           note: "session categories exist only where AVAudioSession does"),
        ])
        #expect(OnPlatformView.receipt(for: claim)
                == "#if os(iOS) || os(tvOS) — session categories exist only where AVAudioSession does")
    }

    @Test func feedIsOneFetchOfTheWholePage() throws {
        let outputs = try SiteGenerator.plan(site: makeSite())
        let data = outputs.first { $0.path == "api/on/visionos.json" }!.bytes
        let feed = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(feed["platform"] as? String == "visionOS")
        let stats = feed["stats"] as! [String: Int]
        #expect(stats["supported"] == 2)
        #expect(stats["unsupported"] == 1)
        #expect(stats["unknown"] == 1)
        #expect(stats["records"] == 4)
        #expect(stats["packages"] == 4)

        let builtIn = feed["builtIn"] as! [[String: Any]]
        #expect(builtIn.count == 1)
        #expect(builtIn[0]["name"] as? String == "AVFAudio")
        let coverage = builtIn[0]["capabilities"] as! [[String: Any]]
        #expect(coverage[0]["floor"] as? String == "visionOS 1.0+")

        let fenced = feed["fenced"] as! [[String: Any]]
        #expect(fenced.count == 1)
        let fences = fenced[0]["fences"] as! [[String: Any]]
        #expect(fences[0]["compilerProven"] as? Bool == true)
        #expect((fences[0]["receipt"] as! String).contains("statusBarOrientation"))
        #expect(fences[0]["worksOn"] as! [String] == ["iOS", "macOS"])

        let unknowns = feed["unknowns"] as! [[String: Any]]
        #expect(unknowns.count == 1)
        #expect(unknowns[0]["why"] as? String == "empty manifest")

        let capabilities = feed["capabilities"] as! [[String: Any]]
        let playback = capabilities.first { $0["id"] as! String == "audio.playback" }!
        #expect(playback["supported"] as? Int == 1)     // AudioKit; AVFAudio is built-in
        #expect(playback["packages"] as? Int == 1)
        #expect(playback["builtInCovers"] as? Bool == true)
        #expect(playback["truthTable"] as? String == "/can/audio.playback/?on=visionOS")

        // The in-scene detail panels render the roster from these — the
        // whole scene stays one fetch.
        #expect(playback["builtInNames"] as? [String] == ["AVFAudio"])
        let verdicts = playback["verdicts"] as! [[String: Any]]
        #expect(verdicts.count == 1)
        #expect(verdicts[0]["name"] as? String == "AudioKit")
        #expect(verdicts[0]["slug"] as? String == "audiokit")
        #expect(verdicts[0]["status"] as? String == "supported")
    }

    @Test func immersiveEntryIsPivotOnlyAndDegradesToNothing() throws {
        let outputs = try SiteGenerator.plan(site: makeSite())
        let pivot = String(decoding: outputs.first { $0.path == "on/visionos/index.html" }!.bytes,
                           as: UTF8.self)
        // The slot ships hidden — with JS off (or no immersive support) the
        // page renders exactly as before the WebXR layer existed.
        #expect(pivot.contains("<div class=\"xr-slot\" data-xr hidden></div>"))
        #expect(pivot.contains("<script src=\"/xr-entry.js\" defer></script>"))
        // No other page pays for the entry script.
        for path in ["index.html", "menu/index.html", "can/audio.playback/index.html",
                     "package/audiokit/index.html"] {
            let page = String(decoding: outputs.first { $0.path == path }!.bytes, as: UTF8.self)
            #expect(!page.contains("xr-entry.js"), "\(path) should not load xr-entry.js")
        }
    }

    @Test func homeAndMenuLinkToThePivot() throws {
        let outputs = try SiteGenerator.plan(site: makeSite())
        let home = String(decoding: outputs.first { $0.path == "index.html" }!.bytes, as: UTF8.self)
        let menu = String(decoding: outputs.first { $0.path == "menu/index.html" }!.bytes, as: UTF8.self)
        #expect(home.contains("href=\"/on/visionos/\""))
        #expect(menu.contains("href=\"/on/visionos/\""))
    }

    @Test func basePathPrefixesPivotHrefs() throws {
        let outputs = try SiteGenerator.plan(site: makeSite(basePath: "/swiftserve"))
        let page = String(decoding: outputs.first { $0.path == "on/visionos/index.html" }!.bytes,
                          as: UTF8.self)
        #expect(page.contains("href=\"/swiftserve/can/audio.playback/?on=visionOS\""))
        #expect(page.contains("href=\"/swiftserve/package/avfaudio/\""))
    }
}
