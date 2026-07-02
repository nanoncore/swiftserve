import Foundation

/// The tunables for build-cost analysis. Kept tiny and code-only this slice (unlike the
/// build-timing `TimingConfig`, which is bundled JSON) — the cost notes are contextual
/// (they quote names and percentages), so there is little static copy to externalize. A
/// bundled `build-cost.config.json` can layer on later without reshaping the report.
public struct CostConfig: Sendable, Equatable {
    /// A dependency at or above this share of the build is "expensive" — the cost half of the
    /// expensive-AND-unhealthy highlight. Below it, a poor health score isn't worth a build-cost
    /// callout (the dependency-health scan owns that conversation).
    public let expensiveSharePercent: Double
    /// Offline health at or below this is "unhealthy" — the health half of the same highlight.
    public let unhealthyScoreMax: Int
    /// How many rows the card details before folding the rest into an "everything else" line.
    /// JSON always carries every entry.
    public let topN: Int

    public init(expensiveSharePercent: Double, unhealthyScoreMax: Int, topN: Int) {
        self.expensiveSharePercent = expensiveSharePercent
        self.unhealthyScoreMax = unhealthyScoreMax
        self.topN = topN
    }

    public func with(topN v: Int) -> CostConfig {
        CostConfig(expensiveSharePercent: expensiveSharePercent, unhealthyScoreMax: unhealthyScoreMax, topN: v)
    }

    /// Shipping defaults: a dependency must be ≥10% of the build and score ≤60 to be flagged as
    /// an expensive-and-unhealthy bet; the card details the top 8 rows.
    public static let `default` = CostConfig(expensiveSharePercent: 10.0, unhealthyScoreMax: 60, topN: 8)
}
