import Foundation

/// Live GitHub enrichment — additive, never required.
///
/// For each GitHub-hosted pin it gathers last-push recency + archived flag +
/// license (one call), the latest semver tag (one call), and contributor count
/// for bus factor (one call). Non-GitHub pins (registry, other forges, local
/// paths) are skipped. Every call is best-effort: any failure or rate-limit
/// leaves that repo with no data, and the scorer falls back to neutral baselines.
///
/// An optional token (`GITHUB_TOKEN`) lifts the rate limit from 60/hr to 5000/hr;
/// without one this still works but should be used sparingly.
public struct GitHubEnrichment: Enrichment {
    public let token: String?
    /// Max repos fetched at once — polite, and keeps a scan responsive.
    public let maxConcurrent: Int

    public init(token: String? = nil, maxConcurrent: Int = 6) {
        self.token = token
        self.maxConcurrent = maxConcurrent
    }

    public var sourceName: String { "github" }
    public var usesNetwork: Bool { true }

    public func enrich(_ pins: [Pin]) async -> [String: EnrichmentData] {
        let targets: [(identity: String, owner: String, repo: String)] = pins.compactMap { pin in
            guard pin.kind == .remoteSourceControl,
                  let or = GitHubParsing.ownerRepo(from: pin.location) else { return nil }
            return (pin.identity, or.owner, or.repo)
        }
        guard !targets.isEmpty else { return [:] }

        let client = GitHubClient(token: token)
        var result: [String: EnrichmentData] = [:]

        await withTaskGroup(of: (String, EnrichmentData?).self) { group in
            let window = max(1, min(maxConcurrent, targets.count))
            var next = 0
            while next < window {
                let t = targets[next]
                group.addTask { (t.identity, await Self.fetch(client, owner: t.owner, repo: t.repo)) }
                next += 1
            }
            while let (id, data) = await group.next() {
                if let data { result[id] = data }
                if next < targets.count {
                    let t = targets[next]
                    group.addTask { (t.identity, await Self.fetch(client, owner: t.owner, repo: t.repo)) }
                    next += 1
                }
            }
        }
        return result
    }

    /// Fetch the three signals concurrently; tolerate any of them failing.
    private static func fetch(_ client: GitHubClient, owner: String, repo: String) async -> EnrichmentData? {
        async let repoData = try? client.repo(owner: owner, name: repo)
        async let tagData = try? client.latestTag(owner: owner, name: repo)
        async let contribData = try? client.contributorCount(owner: owner, name: repo)

        let r = await repoData
        let latest: String? = (await tagData) ?? nil
        let count: Int? = await contribData

        guard r != nil || latest != nil || count != nil else { return nil }

        var d = EnrichmentData()
        if let r {
            d.archived = r.archived
            d.lastReleaseDate = r.pushedAt
            // GitHub returns a null license object when it finds none → treat as "none".
            d.license = r.license.map { GitHubParsing.license(fromSPDX: $0.spdxId) } ?? License.none
        }
        d.latestVersion = latest
        d.contributorCount = count
        return d
    }
}
