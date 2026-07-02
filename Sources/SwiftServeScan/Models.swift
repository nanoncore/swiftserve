import Foundation

/// What kind of thing a symbol is — selects which denylist entries can match it.
public enum SymbolKind: String, Codable, Sendable, Equatable {
    case importedSymbol   // an undefined/imported C or Swift symbol (nm -u)
    case objcClass        // a referenced Objective-C class (_OBJC_CLASS_$_X)
    case objcSelector     // an Objective-C method name / selector
}

/// How seriously to treat a hit. `Comparable` so `--fail-on` can threshold.
public enum Severity: String, Codable, Sendable, Equatable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self { case .low: 0; case .medium: 1; case .high: 2 }
    }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum MatchType: String, Codable, Sendable, Equatable {
    case exact
    case prefix
}

/// Whose code a finding lives in. The headline distinction of slice 2.
public enum OriginKind: String, Codable, Sendable, Equatable {
    case firstParty     // the user's own binary
    case dependency     // a named dependency's compiled artifact
    case unattributed   // a scanned artifact we couldn't map to a known package
}

/// Where a symbol came from, and — when it's a dependency — *which* one.
/// This is the answer to "is this MY problem or a DEPENDENCY's problem?"
public struct Origin: Codable, Sendable, Equatable {
    public let kind: OriginKind
    public let dependency: String?   // package identity, when kind == .dependency
    public let version: String?      // resolved version, when known
    public let artifact: String?     // the binary/artifact it was found in (display)

    public init(kind: OriginKind, dependency: String? = nil, version: String? = nil, artifact: String? = nil) {
        self.kind = kind
        self.dependency = dependency
        self.version = version
        self.artifact = artifact
    }

    enum CodingKeys: String, CodingKey { case kind, dependency, version, artifact }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(dependency, forKey: .dependency)
        try c.encode(version, forKey: .version)
        try c.encode(artifact, forKey: .artifact)
    }
}

/// A symbol pulled out of a Mach-O, tagged with where it came from, before matching.
public struct ExtractedSymbol: Sendable, Equatable {
    public let name: String        // raw, e.g. "_OBJC_CLASS_$_LSApplicationWorkspace", "_MGCopyAnswer"
    public let kind: SymbolKind
    public let origin: Origin

    public init(name: String, kind: SymbolKind, origin: Origin) {
        self.name = name
        self.kind = kind
        self.origin = origin
    }

    /// Name in the form a denylist pattern is written against:
    /// strip the ObjC class sigil, or a single leading `_` for C symbols.
    /// Selectors are matched verbatim (a leading `_` there is meaningful).
    public var normalizedName: String {
        switch kind {
        case .objcClass:
            for sigil in ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"] where name.hasPrefix(sigil) {
                return String(name.dropFirst(sigil.count))
            }
            return name
        case .importedSymbol:
            return name.hasPrefix("_") ? String(name.dropFirst()) : name
        case .objcSelector:
            return name
        }
    }
}

/// One private-API hit, carrying the explanation that is SwiftServe's edge, plus the
/// `origin` that says whose code it's in. Shared across surfaces: the binary/deps
/// scans fill the denylist-derived fields; the source scan adds `confidence` and a
/// precise `location`. The denylist-only fields are optional so a source
/// *needs-review* finding — which by definition matched no denylist entry — doesn't
/// have to invent a framework or pattern it never had.
public struct Finding: Codable, Sendable, Equatable {
    public let symbol: String          // normalized name / flagged string that matched
    public let rawSymbol: String       // exact extracted name, as written
    public let symbolKind: SymbolKind?  // nil for KVC keys / load paths (no symbol kind)
    public let matchType: MatchType?    // nil when there was no denylist match (heuristic only)
    public let matchedPattern: String?  // the denylist pattern, when one matched
    public let framework: String?       // the denylist entry's framework, when one matched
    public let severity: Severity
    public let explanation: String
    public let rejectionCode: String?
    public let alternative: String?
    public let reference: String?
    public let origin: Origin

    // Slice 3 — source surface. Null on binary/deps findings (explicit, for a stable schema).
    public let surface: Surface
    public let confidence: Confidence?
    public let location: SourceLocation?
    public let analyzer: SourceAnalyzer?

    public init(symbol: String, rawSymbol: String, symbolKind: SymbolKind?, matchType: MatchType?,
                matchedPattern: String?, framework: String?, severity: Severity, explanation: String,
                rejectionCode: String?, alternative: String?, reference: String?, origin: Origin,
                surface: Surface = .binary, confidence: Confidence? = nil,
                location: SourceLocation? = nil, analyzer: SourceAnalyzer? = nil) {
        self.symbol = symbol; self.rawSymbol = rawSymbol; self.symbolKind = symbolKind
        self.matchType = matchType; self.matchedPattern = matchedPattern; self.framework = framework
        self.severity = severity; self.explanation = explanation; self.rejectionCode = rejectionCode
        self.alternative = alternative; self.reference = reference; self.origin = origin
        self.surface = surface; self.confidence = confidence
        self.location = location; self.analyzer = analyzer
    }

    enum CodingKeys: String, CodingKey {
        case symbol, rawSymbol, symbolKind, matchType, matchedPattern, framework, severity
        case explanation, rejectionCode, alternative, reference, origin
        case surface, confidence, location, analyzer
    }

    // Emit every optional field as explicit `null` for a stable, predictable schema.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(rawSymbol, forKey: .rawSymbol)
        try c.encode(symbolKind, forKey: .symbolKind)
        try c.encode(matchType, forKey: .matchType)
        try c.encode(matchedPattern, forKey: .matchedPattern)
        try c.encode(framework, forKey: .framework)
        try c.encode(severity, forKey: .severity)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(rejectionCode, forKey: .rejectionCode)
        try c.encode(alternative, forKey: .alternative)
        try c.encode(reference, forKey: .reference)
        try c.encode(origin, forKey: .origin)
        try c.encode(surface, forKey: .surface)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(location, forKey: .location)
        try c.encode(analyzer, forKey: .analyzer)
    }
}
