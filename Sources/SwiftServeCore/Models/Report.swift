import Foundation

/// The canonical, versioned output of a scan — a "Scoop".
///
/// This JSON is the source of truth: the web card is *rendered from* it and a
/// future CLI will print the *same* structure. Nothing about the human card is
/// built separately.
public struct Report: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let overall: Overall
    public let packages: [PackageReport]
    public let graph: GraphMetrics
    public let enrichment: EnrichmentInfo

    public static let currentVersion = 1

    public init(
        reportVersion: Int = Report.currentVersion,
        generatedAt: String,
        overall: Overall,
        packages: [PackageReport],
        graph: GraphMetrics,
        enrichment: EnrichmentInfo
    ) {
        self.reportVersion = reportVersion
        self.generatedAt = generatedAt
        self.overall = overall
        self.packages = packages
        self.graph = graph
        self.enrichment = enrichment
    }
}

/// Top-line result: the number Swiftee reacts to, plus the mood it produced.
public struct Overall: Codable, Sendable, Equatable {
    public let score: Int
    public let mood: Mood
    public let voiceLine: String
    public let headline: String

    public init(score: Int, mood: Mood, voiceLine: String, headline: String) {
        self.score = score
        self.mood = mood
        self.voiceLine = voiceLine
        self.headline = headline
    }
}

/// The six rubric dimensions, each 0–100. Where no data is available (e.g. a
/// file-only scan with no network), these hold the configured neutral baseline.
public struct SubScores: Codable, Sendable, Equatable {
    public let maintenance: Int
    public let staleness: Int
    public let busFactor: Int
    public let swift6: Int
    public let hygiene: Int
    public let license: Int

    public init(maintenance: Int, staleness: Int, busFactor: Int, swift6: Int, hygiene: Int, license: Int) {
        self.maintenance = maintenance
        self.staleness = staleness
        self.busFactor = busFactor
        self.swift6 = swift6
        self.hygiene = hygiene
        self.license = license
    }
}

/// Per-dependency result with one plain-English reason and any raised flags.
public struct PackageReport: Codable, Sendable, Equatable {
    public let identity: String
    public let name: String
    public let kind: PinKind
    public let location: String
    public let resolvedVersion: String?
    public let latestVersion: String?
    /// Branch name for a branch pin, else `nil` — surfaced so the card can show `@main`.
    public let branch: String?
    public let pinType: PinType
    public let score: Int
    public let subScores: SubScores
    public let reason: String
    public let flags: [String]

    public init(
        identity: String,
        name: String,
        kind: PinKind,
        location: String,
        resolvedVersion: String?,
        latestVersion: String?,
        branch: String?,
        pinType: PinType,
        score: Int,
        subScores: SubScores,
        reason: String,
        flags: [String]
    ) {
        self.identity = identity
        self.name = name
        self.kind = kind
        self.location = location
        self.resolvedVersion = resolvedVersion
        self.latestVersion = latestVersion
        self.branch = branch
        self.pinType = pinType
        self.score = score
        self.subScores = subScores
        self.reason = reason
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey {
        case identity, name, kind, location, resolvedVersion, latestVersion, branch, pinType, score, subScores, reason, flags
    }

    // Encode `resolvedVersion`/`latestVersion`/`branch` as explicit `null` when
    // unknown, so the schema is stable for the CLI / AI consumers (missing ≠ null).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(location, forKey: .location)
        try c.encode(resolvedVersion, forKey: .resolvedVersion)
        try c.encode(latestVersion, forKey: .latestVersion)
        try c.encode(branch, forKey: .branch)
        try c.encode(pinType, forKey: .pinType)
        try c.encode(score, forKey: .score)
        try c.encode(subScores, forKey: .subScores)
        try c.encode(reason, forKey: .reason)
        try c.encode(flags, forKey: .flags)
    }
}

/// Two repos resolved from different locations under the same name — usually a
/// fork pinned alongside its upstream. A real supply-chain smell.
public struct DuplicateGroup: Codable, Sendable, Equatable {
    public let name: String
    public let locations: [String]

    public init(name: String, locations: [String]) {
        self.name = name
        self.locations = locations
    }
}

/// Graph-shape metrics. `direct`/`transitive`/`maxDepth` are `nil` on purpose:
/// `Package.resolved` is a *flat* set, so distinguishing direct from transitive
/// (and computing depth) requires the `Package.swift` manifest, which the web
/// path deliberately never accepts.
public struct GraphMetrics: Codable, Sendable, Equatable {
    public let total: Int
    public let direct: Int?
    public let transitive: Int?
    public let maxDepth: Int?
    public let duplicates: [DuplicateGroup]
    public let conflicts: [String]

    public init(
        total: Int,
        direct: Int? = nil,
        transitive: Int? = nil,
        maxDepth: Int? = nil,
        duplicates: [DuplicateGroup],
        conflicts: [String]
    ) {
        self.total = total
        self.direct = direct
        self.transitive = transitive
        self.maxDepth = maxDepth
        self.duplicates = duplicates
        self.conflicts = conflicts
    }

    enum CodingKeys: String, CodingKey {
        case total, direct, transitive, maxDepth, duplicates, conflicts
    }

    // Emit `direct`/`transitive`/`maxDepth` as explicit `null` — the honest
    // signal that these need the manifest and aren't being guessed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(total, forKey: .total)
        try c.encode(direct, forKey: .direct)
        try c.encode(transitive, forKey: .transitive)
        try c.encode(maxDepth, forKey: .maxDepth)
        try c.encode(duplicates, forKey: .duplicates)
        try c.encode(conflicts, forKey: .conflicts)
    }
}

/// Where the enrichment data came from. `fileOnly` means zero network was used —
/// always sufficient to produce a useful report.
public struct EnrichmentInfo: Codable, Sendable, Equatable {
    public let source: String
    public let networkUsed: Bool

    public init(source: String, networkUsed: Bool) {
        self.source = source
        self.networkUsed = networkUsed
    }
}
