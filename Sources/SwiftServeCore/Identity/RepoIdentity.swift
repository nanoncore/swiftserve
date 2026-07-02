import Foundation

/// Repo-identity helpers shared by scoring, enrichment, and the capability
/// corpus pipeline. Pure and network-free — promoted to public because
/// package identity (canonical URL, owner/repo, version tags) is now a
/// product-level concept, not an enrichment detail.
public enum RepoIdentity {

    /// Extract `(owner, repo)` from a GitHub clone URL (https or scp form).
    /// Returns nil for non-GitHub locations (registry, other forges, local paths).
    public static func ownerRepo(from location: String) -> (owner: String, repo: String)? {
        var loc = location
        if loc.hasSuffix(".git") { loc = String(loc.dropLast(4)) }

        if let comps = URLComponents(string: loc),
           let host = comps.host?.lowercased(), host == "github.com" || host == "www.github.com" {
            let parts = comps.path.split(separator: "/").map(String.init)
            if parts.count >= 2 { return (parts[0], parts[1]) }
        }
        // scp-like: git@github.com:owner/repo
        if let range = loc.range(of: "github.com:") {
            let parts = loc[range.upperBound...].split(separator: "/").map(String.init)
            if parts.count >= 2 { return (parts[0], parts[1]) }
        }
        return nil
    }

    /// The canonical form used to key records and dedupe corpora: lowercase,
    /// no `.git`, no trailing slash; GitHub URLs normalize to
    /// `https://github.com/owner/repo`.
    public static func canonicalURL(_ location: String) -> String {
        if let (owner, repo) = ownerRepo(from: location) {
            return "https://github.com/\(owner.lowercased())/\(repo.lowercased())"
        }
        var loc = location
        if loc.hasSuffix(".git") { loc = String(loc.dropLast(4)) }
        while loc.hasSuffix("/") { loc = String(loc.dropLast()) }
        return loc.lowercased()
    }
}

/// Minimal semantic-version reader: tolerant of a leading `v` and any
/// pre-release/build suffix. Only major/minor/patch are compared; the
/// `prerelease` flag lets tag-pickers skip `2.0.0-beta.1` and friends.
public struct SemVer: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: Bool

    public init?(_ string: String) {
        var s = string
        if s.hasPrefix("v") { s.removeFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
        self.prerelease = s.contains("-")
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The highest stable tag among raw tag strings (prereleases and
    /// non-semver tags are ignored). Returns the original tag text.
    public static func maxStableTag(_ tags: [String]) -> String? {
        tags.compactMap { tag -> (SemVer, String)? in
            guard let v = SemVer(tag), !v.prerelease else { return nil }
            return (v, tag)
        }
        .max { $0.0 < $1.0 }?.1
    }
}
