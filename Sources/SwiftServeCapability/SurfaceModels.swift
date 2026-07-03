import Foundation

// The deterministic layer's output: a package's public API surface × platform
// conditionals, extracted by parsing (never by compiling, never by guessing).
// These are plain-data models — SwiftServeSurface produces them, the resolver
// and validator consume them, and the JSON they encode to is canonical
// interchange between pipeline stages. Optionals encode as explicit null for
// a stable, predictable schema (same discipline as the Build pillar).

/// What kind of declaration a `SurfaceDecl` is.
public enum DeclKind: String, Codable, Sendable {
    case function
    case property
    case initializer
    case `subscript`
    case enumCase
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case actor
    case `typealias`
}

/// Where a declaration lives, repo-relative — the anchor every evidence link
/// (and every GitHub permalink) hangs off.
public struct SurfaceLocation: Codable, Sendable, Equatable {
    public let file: String
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// A parsed `#if` compilation condition. Structured so the resolver can
/// evaluate it per platform; anything the parser can't understand becomes
/// `.unknown(rawText)` — we record, we never guess.
public indirect enum PlatformCondition: Sendable, Equatable {
    case os(String)                  // os(iOS)
    case canImport(String)           // canImport(UIKit)
    case targetEnvironment(String)   // targetEnvironment(macCatalyst)
    case arch(String)                // arch(arm64)
    case languageVersion(String)     // swift(>=5.9) / compiler(>=6.0) — raw text
    case flag(String)                // DEBUG and friends
    case not(PlatformCondition)
    case allOf([PlatformCondition])
    case anyOf([PlatformCondition])
    case unknown(String)             // unparseable — carries the exact source text

    /// Conjunction that stays minimal: empty → nil, single → itself.
    public static func conjunction(_ conditions: [PlatformCondition]) -> PlatformCondition? {
        switch conditions.count {
        case 0: nil
        case 1: conditions[0]
        default: .allOf(conditions)
        }
    }

    /// Canonical human-readable rendering — what `rawCondition` shows. For
    /// `#else` branches there is no literal source text, so we render the
    /// effective condition instead (e.g. `!os(iOS) && !os(macOS)`).
    public var rendered: String {
        switch self {
        case .os(let name): "os(\(name))"
        case .canImport(let module): "canImport(\(module))"
        case .targetEnvironment(let env): "targetEnvironment(\(env))"
        case .arch(let arch): "arch(\(arch))"
        case .languageVersion(let raw): raw
        case .flag(let name): name
        case .not(let operand): "!\(operand.parenthesizedIfCompound)"
        case .allOf(let operands): operands.map(\.parenthesizedIfCompound).joined(separator: " && ")
        case .anyOf(let operands): operands.map(\.parenthesizedIfCompound).joined(separator: " || ")
        case .unknown(let raw): raw
        }
    }

    private var parenthesizedIfCompound: String {
        switch self {
        case .allOf, .anyOf: "(\(rendered))"
        default: rendered
        }
    }
}

extension PlatformCondition: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, operand, operands }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .os(let v):
            try c.encode("os", forKey: .kind); try c.encode(v, forKey: .value)
        case .canImport(let v):
            try c.encode("canImport", forKey: .kind); try c.encode(v, forKey: .value)
        case .targetEnvironment(let v):
            try c.encode("targetEnvironment", forKey: .kind); try c.encode(v, forKey: .value)
        case .arch(let v):
            try c.encode("arch", forKey: .kind); try c.encode(v, forKey: .value)
        case .languageVersion(let v):
            try c.encode("languageVersion", forKey: .kind); try c.encode(v, forKey: .value)
        case .flag(let v):
            try c.encode("flag", forKey: .kind); try c.encode(v, forKey: .value)
        case .unknown(let v):
            try c.encode("unknown", forKey: .kind); try c.encode(v, forKey: .value)
        case .not(let operand):
            try c.encode("not", forKey: .kind); try c.encode(operand, forKey: .operand)
        case .allOf(let operands):
            try c.encode("allOf", forKey: .kind); try c.encode(operands, forKey: .operands)
        case .anyOf(let operands):
            try c.encode("anyOf", forKey: .kind); try c.encode(operands, forKey: .operands)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "os": self = .os(try c.decode(String.self, forKey: .value))
        case "canImport": self = .canImport(try c.decode(String.self, forKey: .value))
        case "targetEnvironment": self = .targetEnvironment(try c.decode(String.self, forKey: .value))
        case "arch": self = .arch(try c.decode(String.self, forKey: .value))
        case "languageVersion": self = .languageVersion(try c.decode(String.self, forKey: .value))
        case "flag": self = .flag(try c.decode(String.self, forKey: .value))
        case "unknown": self = .unknown(try c.decode(String.self, forKey: .value))
        case "not": self = .not(try c.decode(PlatformCondition.self, forKey: .operand))
        case "allOf": self = .allOf(try c.decode([PlatformCondition].self, forKey: .operands))
        case "anyOf": self = .anyOf(try c.decode([PlatformCondition].self, forKey: .operands))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown PlatformCondition kind ‘\(kind)’")
        }
    }
}

/// One platform's slice of an `@available` attribute. A decl carries every
/// constraint that applies to it, its own and its enclosing types' merged.
public struct AvailabilityConstraint: Codable, Sendable, Equatable {
    public let platform: String      // "iOS" | "macOS" | … | "*" | "swift"
    public let introduced: String?
    /// Version text when the attribute gave one; "unversioned" for a bare
    /// `deprecated` flag. Deprecation never flips presence — metadata only.
    public let deprecated: String?
    public let obsoleted: String?
    public let unavailable: Bool
    public let message: String?

    public init(platform: String, introduced: String? = nil, deprecated: String? = nil,
                obsoleted: String? = nil, unavailable: Bool = false, message: String? = nil) {
        self.platform = platform
        self.introduced = introduced
        self.deprecated = deprecated
        self.obsoleted = obsoleted
        self.unavailable = unavailable
        self.message = message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(platform, forKey: .platform)
        try c.encode(introduced, forKey: .introduced)
        try c.encode(deprecated, forKey: .deprecated)
        try c.encode(obsoleted, forKey: .obsoleted)
        try c.encode(unavailable, forKey: .unavailable)
        try c.encode(message, forKey: .message)
    }
}

/// The resolver's per-platform answer for one declaration. Three-valued:
/// provably there, provably fenced off, or honestly indeterminate (carrying
/// the condition we couldn't decide).
public enum PlatformPresence: Sendable, Equatable {
    case present
    case absent
    case conditional(String)
}

extension PlatformPresence: Codable {
    private enum CodingKeys: String, CodingKey { case state, condition }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .present: try c.encode("present", forKey: .state)
        case .absent: try c.encode("absent", forKey: .state)
        case .conditional(let condition):
            try c.encode("conditional", forKey: .state)
            try c.encode(condition, forKey: .condition)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "present": self = .present
        case "absent": self = .absent
        case "conditional": self = .conditional(try c.decodeIfPresent(String.self, forKey: .condition) ?? "")
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: c, debugDescription: "unknown PlatformPresence state ‘\(other)’")
        }
    }
}

/// One public declaration on a package's surface — the atom every capability
/// claim must anchor to.
public struct SurfaceDecl: Sendable, Equatable {
    public let name: String                  // qualified: "RoomOptions.noiseCancellationFilter"
    public let kind: DeclKind
    public let signature: String?            // trimmed header, e.g. "func set(enabled: Bool) async throws"
    public let location: SurfaceLocation
    public let condition: PlatformCondition? // conjunction of the enclosing #if stack; nil = unconditional
    public let rawCondition: String?         // rendered condition text — the explainability channel
    public let availability: [AvailabilityConstraint]
    /// Filled by the resolver pass; explicit null straight out of extraction.
    public let resolvedPlatforms: [String: PlatformPresence]?
    public let docSummary: String?
    /// Attached-macro attributes may generate API we can't see — flags the
    /// decl so labeling confidence gets capped, never inflated.
    public let hasMacroAttributes: Bool

    public init(name: String, kind: DeclKind, signature: String?, location: SurfaceLocation,
                condition: PlatformCondition?, rawCondition: String?,
                availability: [AvailabilityConstraint], resolvedPlatforms: [String: PlatformPresence]?,
                docSummary: String?, hasMacroAttributes: Bool) {
        self.name = name
        self.kind = kind
        self.signature = signature
        self.location = location
        self.condition = condition
        self.rawCondition = rawCondition
        self.availability = availability
        self.resolvedPlatforms = resolvedPlatforms
        self.docSummary = docSummary
        self.hasMacroAttributes = hasMacroAttributes
    }

    public func resolving(_ platforms: [String: PlatformPresence]) -> SurfaceDecl {
        SurfaceDecl(name: name, kind: kind, signature: signature, location: location,
                    condition: condition, rawCondition: rawCondition, availability: availability,
                    resolvedPlatforms: platforms, docSummary: docSummary,
                    hasMacroAttributes: hasMacroAttributes)
    }
}

extension SurfaceDecl: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, kind, signature, location, condition, rawCondition
        case availability, resolvedPlatforms, docSummary, hasMacroAttributes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(signature, forKey: .signature)
        try c.encode(location, forKey: .location)
        try c.encode(condition, forKey: .condition)
        try c.encode(rawCondition, forKey: .rawCondition)
        try c.encode(availability, forKey: .availability)
        try c.encode(resolvedPlatforms, forKey: .resolvedPlatforms)
        try c.encode(docSummary, forKey: .docSummary)
        try c.encode(hasMacroAttributes, forKey: .hasMacroAttributes)
    }
}

/// A `platforms:` entry from Package.swift. Version floors only — SPM's
/// `platforms:` never excludes a platform, and the validator enforces that
/// reading (V04).
public struct ManifestPlatform: Codable, Sendable, Equatable {
    public let platform: String
    public let minVersion: String?

    public init(platform: String, minVersion: String?) {
        self.platform = platform
        self.minVersion = minVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(platform, forKey: .platform)
        try c.encode(minVersion, forKey: .minVersion)
    }
}

/// Where a surface came from. No wall-clock timestamp on purpose: extraction
/// at a pinned commit must be byte-identical across runs; time lives in the
/// corpus lockfile, not here.
public struct PackageProvenance: Codable, Sendable, Equatable {
    public let canonicalURL: String?
    public let name: String
    public let tag: String?
    public let commit: String?

    public init(canonicalURL: String?, name: String, tag: String?, commit: String?) {
        self.canonicalURL = canonicalURL
        self.name = name
        self.tag = tag
        self.commit = commit
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canonicalURL, forKey: .canonicalURL)
        try c.encode(name, forKey: .name)
        try c.encode(tag, forKey: .tag)
        try c.encode(commit, forKey: .commit)
    }
}

/// Honest accounting of what extraction covered — and what it couldn't.
public struct SurfaceStats: Codable, Sendable, Equatable {
    public let swiftFiles: Int
    /// ObjC files extraction could NOT parse: implementations (`.m`, private
    /// by construction), private headers, and anything the header scanner
    /// declined — surfaced, not hidden, so labeling stays honest.
    public let objcFiles: Int
    /// Public ObjC headers the header scanner DID turn into decls. Zero on
    /// surfaces extracted before the ObjC pass existed (legacy-tolerant).
    public let objcHeadersParsed: Int
    public let declCount: Int
    public let parseFailures: Int
    public let manifestUnparsed: Bool
    /// The manifest ships `.binaryTarget(...)`s — the real capability fence
    /// may live inside a binary we can't parse (LiveKit's Krisp filter does
    /// exactly this). Caps labeling confidence.
    public let hasBinaryTargets: Bool

    public init(swiftFiles: Int, objcFiles: Int, objcHeadersParsed: Int = 0, declCount: Int,
                parseFailures: Int, manifestUnparsed: Bool, hasBinaryTargets: Bool = false) {
        self.swiftFiles = swiftFiles
        self.objcFiles = objcFiles
        self.objcHeadersParsed = objcHeadersParsed
        self.declCount = declCount
        self.parseFailures = parseFailures
        self.manifestUnparsed = manifestUnparsed
        self.hasBinaryTargets = hasBinaryTargets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swiftFiles = try c.decode(Int.self, forKey: .swiftFiles)
        objcFiles = try c.decode(Int.self, forKey: .objcFiles)
        objcHeadersParsed = try c.decodeIfPresent(Int.self, forKey: .objcHeadersParsed) ?? 0
        declCount = try c.decode(Int.self, forKey: .declCount)
        parseFailures = try c.decode(Int.self, forKey: .parseFailures)
        manifestUnparsed = try c.decode(Bool.self, forKey: .manifestUnparsed)
        hasBinaryTargets = try c.decode(Bool.self, forKey: .hasBinaryTargets)
    }
}

/// The whole deterministic layer for one package at one commit.
public struct PackageSurface: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let surfaceVersion: Int
    public let package: PackageProvenance
    public let manifestPlatforms: [ManifestPlatform]
    public let decls: [SurfaceDecl]
    public let stats: SurfaceStats

    public init(surfaceVersion: Int = PackageSurface.currentVersion, package: PackageProvenance,
                manifestPlatforms: [ManifestPlatform], decls: [SurfaceDecl], stats: SurfaceStats) {
        self.surfaceVersion = surfaceVersion
        self.package = package
        self.manifestPlatforms = manifestPlatforms
        self.decls = decls
        self.stats = stats
    }
}
