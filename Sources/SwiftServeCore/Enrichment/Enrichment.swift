import Foundation

/// A software license, bucketed by the awareness it warrants.
public enum License: String, Sendable, Equatable {
    case permissive   // MIT, Apache-2.0, BSD — good
    case copyleft     // GPL, LGPL, MPL — awareness flag
    case none         // no license file — penalty
    case unknown      // couldn't determine
}

/// Everything an enrichment source *might* learn about a dependency beyond what
/// the resolved file contains. Every field is optional: a `nil` field means
/// "unknown", and the scorer falls back to its neutral baseline for it.
public struct EnrichmentData: Sendable, Equatable {
    public var lastReleaseDate: Date?
    public var latestVersion: String?
    public var archived: Bool?
    public var contributorCount: Int?
    public var license: License?
    public var swift6Ready: Bool?

    public init(
        lastReleaseDate: Date? = nil,
        latestVersion: String? = nil,
        archived: Bool? = nil,
        contributorCount: Int? = nil,
        license: License? = nil,
        swift6Ready: Bool? = nil
    ) {
        self.lastReleaseDate = lastReleaseDate
        self.latestVersion = latestVersion
        self.archived = archived
        self.contributorCount = contributorCount
        self.license = license
        self.swift6Ready = swift6Ready
    }
}

/// A source of additive dependency intelligence.
///
/// The contract is a hard one: enrichment is **additive, never required**. A
/// conforming type may return an empty dictionary (the file-only case) and the
/// scorer must still produce a useful report.
public protocol Enrichment: Sendable {
    /// Label recorded in the report's `enrichment.source`.
    var sourceName: String { get }
    /// Whether producing this data touches the network.
    var usesNetwork: Bool { get }
    /// Enrichment keyed by pin `identity`. Missing keys → unknown → neutral.
    func enrich(_ pins: [Pin]) async -> [String: EnrichmentData]
}
