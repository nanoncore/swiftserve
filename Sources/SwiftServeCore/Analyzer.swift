import Foundation

/// The one call the web (and later, the CLI) makes: raw `Package.resolved` bytes
/// in, canonical ``Report`` out. Wires parsing → enrichment → scoring together.
public struct Analyzer: Sendable {
    public let config: ScoringConfig
    public let enrichment: Enrichment

    public init(config: ScoringConfig = .default, enrichment: Enrichment = FileOnlyEnrichment()) {
        self.config = config
        self.enrichment = enrichment
    }

    /// Parse, enrich, and score. Throws ``PackageResolvedError`` on bad input.
    public func analyze(resolved data: Data, generatedAt: String? = nil) async throws -> Report {
        let pins = try PackageResolvedParser().parse(data)
        let enriched = await enrichment.enrich(pins)
        return Scorer(config: config).buildReport(
            pins: pins,
            enrichment: enriched,
            source: enrichment.sourceName,
            networkUsed: enrichment.usesNetwork,
            generatedAt: generatedAt ?? Analyzer.timestamp()
        )
    }

    public func analyze(resolved string: String, generatedAt: String? = nil) async throws -> Report {
        try await analyze(resolved: Data(string.utf8), generatedAt: generatedAt)
    }

    /// ISO-8601 timestamp for `generatedAt`.
    public static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
