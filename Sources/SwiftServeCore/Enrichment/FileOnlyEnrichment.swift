import Foundation

/// The default, zero-network enrichment: it learns nothing beyond the resolved
/// file itself, so it returns no per-package data. The scorer derives everything
/// it can from the pins directly (hygiene, version-shape staleness) and uses
/// neutral baselines for the dimensions that genuinely need the network.
///
/// This path is the guarantee that SwiftServe always produces a useful report
/// with no token and no connection.
public struct FileOnlyEnrichment: Enrichment {
    public init() {}

    public var sourceName: String { "fileOnly" }
    public var usesNetwork: Bool { false }

    public func enrich(_ pins: [Pin]) async -> [String: EnrichmentData] {
        [:]
    }
}
