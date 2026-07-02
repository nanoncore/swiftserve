import Foundation
import Testing
@testable import SwiftServeCapability
import SwiftServeCore

@Suite struct CorpusTests {

    @Test func domainFilterMatchesOwnerAndRepoCaseInsensitively() {
        let urls = [
            "https://github.com/AudioKit/AudioKit.git",
            "https://github.com/apple/swift-nio.git",
            "https://github.com/someone/CoolVideoPlayer.git",
            "https://github.com/soundly/parsing.git",   // owner matches "sound"
        ]
        let matched = DomainFilter.match(urls: urls, keywords: ["audio", "video", "sound"])
        #expect(matched == [
            "https://github.com/AudioKit/AudioKit.git",
            "https://github.com/someone/CoolVideoPlayer.git",
            "https://github.com/soundly/parsing.git",
        ])
    }

    @Test func seedFileDecodesWithCompanions() throws {
        let json = """
        {"version": 1, "domain": "audio", "keywords": ["audio"],
         "packages": [
            {"url": "https://github.com/livekit/client-sdk-swift", "why": "acceptance"},
            {"url": "https://github.com/livekit/swift-krisp-noise-filter",
             "companionOf": "https://github.com/livekit/client-sdk-swift"}
         ]}
        """
        let seed = try CorpusSeed.decode(from: Data(json.utf8))
        #expect(seed.packages.count == 2)
        #expect(seed.packages[1].companionOf == "https://github.com/livekit/client-sdk-swift")
        #expect(seed.packages[0].companionOf == nil)
    }

    @Test func canonicalURLNormalizesGitHubForms() {
        #expect(RepoIdentity.canonicalURL("https://github.com/LiveKit/Client-SDK-Swift.git")
                == "https://github.com/livekit/client-sdk-swift")
        #expect(RepoIdentity.canonicalURL("git@github.com:livekit/client-sdk-swift.git")
                == "https://github.com/livekit/client-sdk-swift")
        #expect(RepoIdentity.canonicalURL("https://gitlab.com/Team/Pkg/")
                == "https://gitlab.com/team/pkg")
    }

    @Test func maxStableTagSkipsPrereleasesAndNonSemver() {
        #expect(SemVer.maxStableTag(["1.2.0", "v2.0.0", "2.1.0-beta.1", "nightly", "1.9.9"]) == "v2.0.0")
        #expect(SemVer.maxStableTag(["2.1.0-beta.1", "nightly"]) == nil)
    }

    @Test func semverOrdering() {
        #expect(SemVer("1.2.3")! < SemVer("1.10.0")!)
        #expect(SemVer("v2.0.0")! > SemVer("1.99.99")!)
        #expect(SemVer("2.0.0-rc.1")!.prerelease)
        #expect(!SemVer("2.0.0")!.prerelease)
    }
}
