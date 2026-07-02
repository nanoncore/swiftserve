import Foundation
import SwiftServeCore

// The corpus is the package universe the capability index covers, one domain
// at a time. Plain data + a pure filter; the CLI does the network and git.

/// Hand-curated seed file for a domain (`data/corpus/seed.<domain>.json`):
/// known-relevant packages plus the keywords that sweep the package list.
public struct CorpusSeed: Codable, Sendable, Equatable {
    public struct Package: Codable, Sendable, Equatable {
        public let url: String
        public let why: String?
        /// Set when this package exists to serve another (e.g. LiveKit's Krisp
        /// noise filter) — records may cite a companion's surface as evidence.
        public let companionOf: String?

        public init(url: String, why: String? = nil, companionOf: String? = nil) {
            self.url = url
            self.why = why
            self.companionOf = companionOf
        }
    }

    public let version: Int
    public let domain: String
    public let keywords: [String]
    public let packages: [Package]

    public static func decode(from data: Data) throws -> CorpusSeed {
        try JSONDecoder().decode(CorpusSeed.self, from: data)
    }
}

/// One package in a discovered corpus. `source` records how it got here —
/// seeds are trusted, keyword hits await the founder's pruning pass.
public struct DomainCandidate: Codable, Sendable, Equatable {
    public let url: String          // canonical (RepoIdentity.canonicalURL)
    public let name: String         // owner/repo for GitHub, else the URL tail
    public let source: String       // "seed" | "keyword"
    public let why: String?
    public let companionOf: String?

    public init(url: String, name: String, source: String, why: String? = nil, companionOf: String? = nil) {
        self.url = url
        self.name = name
        self.source = source
        self.why = why
        self.companionOf = companionOf
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(why, forKey: .why)
        try c.encode(companionOf, forKey: .companionOf)
    }
}

/// A domain's discovered corpus (`data/corpus/corpus.<domain>.json`) —
/// generated, then hand-pruned; curation is a human step by design.
public struct Corpus: Codable, Sendable, Equatable {
    public let version: Int
    public let domain: String
    public let packages: [DomainCandidate]

    public init(version: Int = 1, domain: String, packages: [DomainCandidate]) {
        self.version = version
        self.domain = domain
        self.packages = packages
    }

    public static func decode(from data: Data) throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: data)
    }
}

/// The reproducibility anchor (`data/corpus/corpus.lock.json`): which tag and
/// commit each package was fetched at. Surfaces rebuild byte-identical from
/// this; wall-clock time lives here and nowhere else.
public struct CorpusLock: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let tag: String
        public let commit: String
        public let fetchedAt: String

        public init(tag: String, commit: String, fetchedAt: String) {
            self.tag = tag
            self.commit = commit
            self.fetchedAt = fetchedAt
        }
    }

    public var version: Int
    public var packages: [String: Entry]   // canonical URL → entry

    public init(version: Int = 1, packages: [String: Entry] = [:]) {
        self.version = version
        self.packages = packages
    }

    public static func decode(from data: Data) throws -> CorpusLock {
        try JSONDecoder().decode(CorpusLock.self, from: data)
    }
}

/// Pure keyword sweep over the package-list URLs. Case-insensitive substring
/// match on the owner/repo string — deliberately loose; the founder prunes.
public enum DomainFilter {
    public static func match(urls: [String], keywords: [String]) -> [String] {
        let lowered = keywords.map { $0.lowercased() }
        return urls.filter { url in
            let name: String
            if let (owner, repo) = RepoIdentity.ownerRepo(from: url) {
                name = "\(owner)/\(repo)".lowercased()
            } else {
                name = url.lowercased()
            }
            return lowered.contains { name.contains($0) }
        }
    }
}
