import Foundation

// The semantic layer's output: capability claims, every one anchored to the
// deterministic surface. Records are curated artifacts (in-repo JSON under
// `data/records/`) — how they were produced (Claude in-session, API, human)
// is irrelevant; `RecordValidator` is the only gate.

/// supported / unsupported / conditional / unknown — the four honest answers.
public enum ClaimStatus: String, Codable, Sendable {
    case supported, unsupported, conditional, unknown
}

/// What kind of proof an anchor is.
public enum EvidenceKind: String, Codable, Sendable {
    /// Positive: this declaration exists on the claimed platform.
    case symbol
    /// Negative: this declaration is fenced off the claimed platform by a `#if`.
    case `guard`
    /// Negative: `@available(P, unavailable)`.
    case availability
    /// Weak: Package.swift `platforms:` — version floors only, NEVER exclusion.
    case manifestPlatforms
    /// Weakest: a README/docs claim. Never sufficient alone for a verdict.
    case readme
}

/// One piece of evidence. Symbol-kind anchors must name a real `SurfaceDecl`
/// (qualified name + file + line) — the validator kills anything that doesn't.
public struct EvidenceAnchor: Sendable, Equatable {
    public let kind: EvidenceKind
    public let symbol: String?
    public let file: String?
    public let line: Int?
    public let condition: String?      // the guard text, e.g. "os(iOS)"
    public let availability: String?   // e.g. "@available(macOS, unavailable)"
    /// Canonical URL when the anchor cites a companion package's surface.
    public let package: String?
    /// For readme evidence: the claim being cited, quoted.
    public let note: String?

    public init(kind: EvidenceKind, symbol: String? = nil, file: String? = nil, line: Int? = nil,
                condition: String? = nil, availability: String? = nil, package: String? = nil,
                note: String? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.file = file
        self.line = line
        self.condition = condition
        self.availability = availability
        self.package = package
        self.note = note
    }
}

extension EvidenceAnchor: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, symbol, file, line, condition, availability, package, note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(file, forKey: .file)
        try c.encode(line, forKey: .line)
        try c.encode(condition, forKey: .condition)
        try c.encode(availability, forKey: .availability)
        try c.encode(package, forKey: .package)
        try c.encode(note, forKey: .note)
    }
}

/// One platform's claim within a record.
public struct PlatformClaim: Codable, Sendable, Equatable {
    public let status: ClaimStatus
    /// 0.0–0.95. There is no 1.0 — the validator enforces the ceiling and the
    /// blind-spot caps (macro-generated API, binary targets, weak evidence).
    public let confidence: Double
    public let evidence: [EvidenceAnchor]

    public init(status: ClaimStatus, confidence: Double, evidence: [EvidenceAnchor]) {
        self.status = status
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Which package, at which pinned truth.
public struct RecordPackage: Sendable, Equatable {
    public let canonicalURL: String
    public let name: String
    public let aliases: [String]
    public let version: String        // the tag the surface was extracted at
    public let commit: String
    public let surfaceDigest: String  // ContentDigest of the surface JSON — drift detector

    public init(canonicalURL: String, name: String, aliases: [String], version: String,
                commit: String, surfaceDigest: String) {
        self.canonicalURL = canonicalURL
        self.name = name
        self.aliases = aliases
        self.version = version
        self.commit = commit
        self.surfaceDigest = surfaceDigest
    }
}

extension RecordPackage: Codable {}

/// A capability reference — id from the governed taxonomy, label denormalized
/// for display.
public struct CapabilityRef: Codable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One package × one capability × every platform — the atom of the index.
public struct CapabilityRecord: Sendable, Equatable {
    public static let currentVersion = 1

    public let recordVersion: Int
    public let package: RecordPackage
    public let capability: CapabilityRef
    public let platforms: [String: PlatformClaim]   // Platform.rawValue → claim
    public let requiresCompanion: [String]          // canonical URLs
    public let notes: String?
    public let labeledBy: String                    // "claude-code-session" | "api" | "human"
    public let labeledAt: String                    // ISO8601 — records are curated artifacts

    public init(recordVersion: Int = CapabilityRecord.currentVersion, package: RecordPackage,
                capability: CapabilityRef, platforms: [String: PlatformClaim],
                requiresCompanion: [String] = [], notes: String? = nil,
                labeledBy: String, labeledAt: String) {
        self.recordVersion = recordVersion
        self.package = package
        self.capability = capability
        self.platforms = platforms
        self.requiresCompanion = requiresCompanion
        self.notes = notes
        self.labeledBy = labeledBy
        self.labeledAt = labeledAt
    }
}

extension CapabilityRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case recordVersion, package, capability, platforms, requiresCompanion, notes, labeledBy, labeledAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordVersion, forKey: .recordVersion)
        try c.encode(package, forKey: .package)
        try c.encode(capability, forKey: .capability)
        try c.encode(platforms, forKey: .platforms)
        try c.encode(requiresCompanion, forKey: .requiresCompanion)
        try c.encode(notes, forKey: .notes)
        try c.encode(labeledBy, forKey: .labeledBy)
        try c.encode(labeledAt, forKey: .labeledAt)
    }
}

/// Dependency-free content digest for drift detection (not cryptographic —
/// it answers "did the surface change since labeling", nothing more).
public enum ContentDigest {
    public static func fnv1a64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return "fnv1a64:" + String(format: "%016llx", hash)
    }
}
