import Foundation
import Testing
@testable import SwiftServeCore

@Suite("GitHub parsing helpers")
struct GitHubParsingTests {

    @Test("Extracts owner/repo from GitHub URLs, skips non-GitHub")
    func ownerRepo() {
        #expect(GitHubParsing.ownerRepo(from: "https://github.com/apple/swift-nio.git")?.owner == "apple")
        #expect(GitHubParsing.ownerRepo(from: "https://github.com/apple/swift-nio.git")?.repo == "swift-nio")
        #expect(GitHubParsing.ownerRepo(from: "https://github.com/apple/swift-nio")?.repo == "swift-nio")
        #expect(GitHubParsing.ownerRepo(from: "git@github.com:apple/swift-nio.git")?.owner == "apple")
        // not GitHub → nil
        #expect(GitHubParsing.ownerRepo(from: "https://gitlab.com/foo/bar.git") == nil)
        #expect(GitHubParsing.ownerRepo(from: "apple.swift-collections") == nil) // registry identity
    }

    @Test("Picks the highest semver tag, ignoring non-semver")
    func maxTag() {
        #expect(GitHubParsing.maxSemverTag(["2.98.0", "2.101.1", "2.100.0", "2.99.0"]) == "2.101.1")
        #expect(GitHubParsing.maxSemverTag(["1.0.0", "1.0.10", "1.0.2"]) == "1.0.10") // numeric, not lexical
        #expect(GitHubParsing.maxSemverTag(["v1.2.0", "v1.3.0"]) == "v1.3.0")
        #expect(GitHubParsing.maxSemverTag(["nightly", "weird"]) == nil)
        #expect(GitHubParsing.maxSemverTag([]) == nil)
    }

    @Test("Parses the rel=\"last\" page from a GitHub Link header")
    func linkHeader() {
        let header = #"<https://api.github.com/.../contributors?per_page=1&page=2>; rel="next", <https://api.github.com/.../contributors?per_page=1&page=244>; rel="last""#
        #expect(GitHubParsing.lastPage(fromLinkHeader: header) == 244)
        #expect(GitHubParsing.lastPage(fromLinkHeader: "no link here") == nil)
    }

    @Test("Buckets SPDX license ids")
    func licenseMapping() {
        #expect(GitHubParsing.license(fromSPDX: "MIT") == .permissive)
        #expect(GitHubParsing.license(fromSPDX: "Apache-2.0") == .permissive)
        #expect(GitHubParsing.license(fromSPDX: "GPL-3.0") == .copyleft)
        #expect(GitHubParsing.license(fromSPDX: "AGPL-3.0") == .copyleft)
        #expect(GitHubParsing.license(fromSPDX: "NOASSERTION") == .unknown)
        #expect(GitHubParsing.license(fromSPDX: nil) == .unknown)
    }

    @Test("Decodes the GitHub repo response (snake_case + ISO date + license)")
    func decodesRepo() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let withLicense = #"{"archived": false, "pushed_at": "2026-06-23T17:41:32Z", "license": {"spdx_id": "Apache-2.0"}}"#
        let r = try decoder.decode(GitHubRepo.self, from: Data(withLicense.utf8))
        #expect(r.archived == false)
        #expect(r.pushedAt != nil)
        #expect(r.license?.spdxId == "Apache-2.0")

        let noLicense = #"{"archived": true, "pushed_at": "2020-01-01T00:00:00Z", "license": null}"#
        let r2 = try decoder.decode(GitHubRepo.self, from: Data(noLicense.utf8))
        #expect(r2.archived == true)
        #expect(r2.license == nil)
    }

    // Opt-in live smoke test against the real GitHub API. Run with:
    //   RUN_LIVE_GITHUB=1 swift test --filter "enriches a real GitHub repo"
    // (uses GITHUB_TOKEN if set; works unauthenticated within the 60/hr limit).
    @Test("LIVE: enriches a real GitHub repo",
          .enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_GITHUB"] == "1"))
    func liveEnrichment() async {
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        let pins = [Pin(identity: "swift-nio", kind: .remoteSourceControl,
                        location: "https://github.com/apple/swift-nio.git",
                        resolvedVersion: "2.50.0", branch: nil, revision: "abc", pinType: .version)]
        let data = await GitHubEnrichment(token: token).enrich(pins)
        let nio = data["swift-nio"]
        #expect(nio != nil)
        #expect(nio?.archived == false)
        #expect(nio?.latestVersion != nil)
        #expect(nio?.license == .permissive)        // Apache-2.0
        #expect((nio?.contributorCount ?? 0) > 1)
        #expect(nio?.lastReleaseDate != nil)
    }

    @Test("enrich() touches no network for non-GitHub pins")
    func enrichSkipsNonGitHub() async {
        let pins = [
            Pin(identity: "swift-collections", kind: .registry, location: "apple.swift-collections",
                resolvedVersion: "1.1.0", branch: nil, revision: nil, pinType: .version),
            Pin(identity: "local-thing", kind: .localSourceControl, location: "/Users/me/local-thing",
                resolvedVersion: nil, branch: nil, revision: "abc", pinType: .revision),
        ]
        let result = await GitHubEnrichment(token: nil).enrich(pins)
        #expect(result.isEmpty)
    }
}

@Suite("Scoring with enrichment data")
struct EnrichedScoringTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000) // fixed reference time
    let scorer = Scorer()

    func pin(_ id: String, _ version: String?) -> Pin {
        Pin(identity: id, kind: .remoteSourceControl,
            location: "https://github.com/apple/\(id).git",
            resolvedVersion: version, branch: nil, revision: "abc", pinType: version == nil ? .revision : .version)
    }

    @Test("Archived dependency: maintenance zero, flag + reason")
    func archived() {
        let data = EnrichmentData(archived: true)
        let r = scorer.score(pin: pin("dead-lib", "1.0.0"), data: data, now: now)
        #expect(r.subScores.maintenance == 0)
        #expect(r.flags.contains("archived"))
        #expect(r.reason == "Archived — no longer maintained.")
    }

    @Test("Behind on majors: low staleness + a clear reason")
    func behindMajors() {
        let data = EnrichmentData(latestVersion: "5.0.0")
        let r = scorer.score(pin: pin("swift-foo", "2.0.0"), data: data, now: now)
        #expect(r.subScores.staleness < 50)
        #expect(r.reason.contains("3 majors behind"))
        #expect(r.latestVersion == "5.0.0")
    }

    @Test("Stale but current version: maintenance reason surfaces")
    func staleMaintenance() {
        let twoYearsAgo = now.addingTimeInterval(-2 * 365 * 86_400)
        let data = EnrichmentData(lastReleaseDate: twoYearsAgo, latestVersion: "1.0.0")
        let r = scorer.score(pin: pin("sleepy", "1.0.0"), data: data, now: now)
        #expect(r.subScores.maintenance == 0) // ~2y old → bottom of the maintenance scale
        #expect(r.reason.contains("No activity"))
    }

    @Test("No license: flagged and penalized")
    func noLicense() {
        let data = EnrichmentData(lastReleaseDate: now, latestVersion: "1.0.0", license: License.none)
        let r = scorer.score(pin: pin("unlicensed", "1.0.0"), data: data, now: now)
        #expect(r.subScores.license == 30)
        #expect(r.flags.contains("noLicense"))
    }

    @Test("Healthy package earns a high score and a warm reason")
    func healthy() {
        let data = EnrichmentData(
            lastReleaseDate: now.addingTimeInterval(-10 * 86_400),
            latestVersion: "1.2.0",
            archived: false,
            contributorCount: 180,
            license: .permissive,
            swift6Ready: true
        )
        let r = scorer.score(pin: pin("healthy", "1.2.0"), data: data, now: now)
        #expect(r.score >= 90)
        #expect(Mood.from(score: r.score) == .partyMode || Mood.from(score: r.score) == .freshSwirl)
        #expect(r.reason == "Up to date and actively maintained.")
    }
}
