import Foundation

/// Repo-identity helpers shared by scoring, enrichment, and the capability
/// corpus pipeline. Pure and network-free — promoted to public because
/// package identity (canonical URL, owner/repo, version tags) is now a
/// product-level concept, not an enrichment detail.
public enum RepoIdentity {

    /// SwiftPM package identities are case-insensitive. Package.resolved v2/v3
    /// already carries the resolved identity, so comparison only canonicalizes
    /// case and surrounding whitespace; it never guesses from a display name.
    public static func normalizedPackageIdentity(_ identity: String) -> String {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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

    /// Preserve source identity while stripping URL user-info so receipts and
    /// diagnostics never echo embedded repository credentials.
    public static func redactedLocation(_ location: String) -> String {
        guard var components = URLComponents(string: location), components.host != nil else {
            return location
        }
        components.user = nil
        components.password = nil
        return components.string ?? location
    }
}

/// SemVer 2.0 reader and precedence implementation. A leading `v` is accepted
/// for Git tags; otherwise the input must be a complete semantic version.
/// Build metadata is retained but deliberately ignored for precedence.
public struct SemVer: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prereleaseIdentifiers: [String]
    public let buildMetadataIdentifiers: [String]

    public var prerelease: Bool { !prereleaseIdentifiers.isEmpty }

    public init?(_ string: String) {
        var text = string
        if text.utf8.first == 118 { text = String(text.dropFirst()) } // leading "v"
        guard !text.isEmpty, !text.utf8.contains(where: { [9, 10, 13, 32].contains($0) }) else { return nil }

        let buildSplit = text.components(separatedBy: "+")
        guard buildSplit.count <= 2, !buildSplit[0].isEmpty else { return nil }
        let versionPart = buildSplit[0]
        let build = buildSplit.count == 2 ? buildSplit[1] : nil

        let prereleaseSplit = versionPart.split(separator: "-", maxSplits: 1,
                                                omittingEmptySubsequences: false).map(String.init)
        guard !prereleaseSplit[0].isEmpty else { return nil }
        let core = prereleaseSplit[0].components(separatedBy: ".")
        guard core.count == 3,
              let major = Self.parseCore(core[0]),
              let minor = Self.parseCore(core[1]),
              let patch = Self.parseCore(core[2]) else { return nil }

        let prerelease = prereleaseSplit.count == 2
            ? prereleaseSplit[1].components(separatedBy: ".")
            : []
        let buildIdentifiers = build?.components(separatedBy: ".") ?? []
        guard Self.validIdentifiers(prerelease, numericLeadingZerosForbidden: true),
              Self.validIdentifiers(buildIdentifiers, numericLeadingZerosForbidden: false) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prerelease
        self.buildMetadataIdentifiers = buildIdentifiers
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        let lhsCore = (lhs.major, lhs.minor, lhs.patch)
        let rhsCore = (rhs.major, rhs.minor, rhs.patch)
        if lhsCore != rhsCore { return lhsCore < rhsCore }
        if lhs.prereleaseIdentifiers.isEmpty { return false }
        if rhs.prereleaseIdentifiers.isEmpty { return true }
        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
            if left == right { continue }
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }

    private static func parseCore(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || !value.hasPrefix("0") else { return nil }
        return Int(value)
    }

    private static func validIdentifiers(_ values: [String], numericLeadingZerosForbidden: Bool) -> Bool {
        values.allSatisfy { value in
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 }) else { return false }
            if numericLeadingZerosForbidden,
               value.utf8.allSatisfy({ (48...57).contains($0) }),
               value.count > 1, value.hasPrefix("0") {
                return false
            }
            return true
        }
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

    /// Highest semantic tag, preferring stable releases. A prerelease is
    /// returned only when the history contains no stable semantic release.
    public static func preferredReleaseTag(_ tags: [String]) -> String? {
        maxStableTag(tags) ?? tags.compactMap { tag -> (SemVer, String)? in
            SemVer(tag).map { ($0, tag) }
        }.max { $0.0 < $1.0 }?.1
    }
}
