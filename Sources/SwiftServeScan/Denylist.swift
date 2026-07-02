import Foundation

/// The curated list of known private symbols/selectors and their explanations —
/// SwiftServe's real asset. Loaded as DATA at runtime so it can grow without a
/// recompile.
public struct Denylist: Codable, Sendable, Equatable {
    public let version: Int
    public let entries: [DenylistEntry]

    public init(version: Int, entries: [DenylistEntry]) {
        self.version = version
        self.entries = entries
    }

    public static func decode(from data: Data) throws -> Denylist {
        try JSONDecoder().decode(Denylist.self, from: data)
    }
}

public struct DenylistEntry: Codable, Sendable, Equatable {
    public let id: String
    public let pattern: String
    public let match: MatchType
    public let appliesTo: [SymbolKind]
    public let framework: String
    public let severity: Severity
    public let why: String
    public let rejectionCode: String?
    public let alternative: String?
    public let reference: String?

    public init(id: String, pattern: String, match: MatchType, appliesTo: [SymbolKind],
                framework: String, severity: Severity, why: String,
                rejectionCode: String? = nil, alternative: String? = nil, reference: String? = nil) {
        self.id = id; self.pattern = pattern; self.match = match; self.appliesTo = appliesTo
        self.framework = framework; self.severity = severity; self.why = why
        self.rejectionCode = rejectionCode; self.alternative = alternative; self.reference = reference
    }
}
