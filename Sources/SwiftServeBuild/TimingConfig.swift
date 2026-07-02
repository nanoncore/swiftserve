import Foundation

/// The tunables for build-time pointers — thresholds, impact cutoffs, the top-N cap, and
/// the suggestion copy. Loaded as DATA at runtime so it can change without a recompile,
/// the same principle as the private-API denylist. A baked-in `.default` keeps the pure
/// pillar (and its tests) working with zero resources.
///
/// The thresholds do double duty: the CLI feeds them to the compiler's
/// `-warn-long-expression-type-checking` / `-warn-long-function-bodies` flags, and the
/// analyzer re-applies them when filtering records (so an ingested log produced at a
/// different limit is still held to the configured bar).
public struct TimingConfig: Codable, Sendable, Equatable {
    public let version: Int
    public let expressionThresholdMs: Int     // warn per expression over this (default 100)
    public let functionBodyThresholdMs: Int   // warn per function body over this (default 200)
    public let topN: Int                      // how many pointers the card details before the rollup
    public let tiers: Tiers
    public let copy: Copy

    public init(version: Int, expressionThresholdMs: Int, functionBodyThresholdMs: Int,
                topN: Int, tiers: Tiers, copy: Copy) {
        self.version = version
        self.expressionThresholdMs = expressionThresholdMs
        self.functionBodyThresholdMs = functionBodyThresholdMs
        self.topN = topN; self.tiers = tiers; self.copy = copy
    }

    /// Cost cutoffs (ms) for the impact tier. At/above `criticalMs` ⇒ critical; at/above
    /// `highMs` ⇒ high; anything else over threshold ⇒ moderate.
    public struct Tiers: Codable, Sendable, Equatable {
        public let criticalMs: Int
        public let highMs: Int
        public init(criticalMs: Int, highMs: Int) {
            self.criticalMs = criticalMs; self.highMs = highMs
        }
    }

    /// Suggestion copy, kept generic on purpose — we point at the *shape* of the fix and
    /// never invent specific API signatures.
    public struct Copy: Codable, Sendable, Equatable {
        public let expressionSuggestion: String
        public let functionBodySuggestion: String
        public let viewBodySuggestion: String   // SwiftUI `body` specifically
        public init(expressionSuggestion: String, functionBodySuggestion: String, viewBodySuggestion: String) {
            self.expressionSuggestion = expressionSuggestion
            self.functionBodySuggestion = functionBodySuggestion
            self.viewBodySuggestion = viewBodySuggestion
        }
    }

    public static func decode(from data: Data) throws -> TimingConfig {
        try JSONDecoder().decode(TimingConfig.self, from: data)
    }

    /// Compute the impact tier for a measured cost.
    public func tier(for costMs: Int) -> ImpactTier {
        if costMs >= tiers.criticalMs { return .critical }
        if costMs >= tiers.highMs { return .high }
        return .moderate
    }

    /// The threshold that applies to a given category.
    public func threshold(for category: PointerCategory) -> Int {
        switch category {
        case .slowExpression: expressionThresholdMs
        case .slowFunctionBody: functionBodyThresholdMs
        }
    }

    // Builder-style copies so the CLI can layer `--expr-threshold` / `--body-threshold` /
    // `--top` overrides onto whichever config it loaded.
    public func with(expressionThresholdMs v: Int) -> TimingConfig {
        TimingConfig(version: version, expressionThresholdMs: v, functionBodyThresholdMs: functionBodyThresholdMs,
                     topN: topN, tiers: tiers, copy: copy)
    }
    public func with(functionBodyThresholdMs v: Int) -> TimingConfig {
        TimingConfig(version: version, expressionThresholdMs: expressionThresholdMs, functionBodyThresholdMs: v,
                     topN: topN, tiers: tiers, copy: copy)
    }
    public func with(topN v: Int) -> TimingConfig {
        TimingConfig(version: version, expressionThresholdMs: expressionThresholdMs,
                     functionBodyThresholdMs: functionBodyThresholdMs, topN: v, tiers: tiers, copy: copy)
    }

    /// Shipping defaults. Mirrors the bundled `build-timing.config.json`; the code copy is
    /// the source of truth the pillar can always fall back to.
    public static let `default` = TimingConfig(
        version: 1,
        expressionThresholdMs: 100,
        functionBodyThresholdMs: 200,
        topN: 5,
        tiers: Tiers(criticalMs: 800, highMs: 400),
        copy: Copy(
            expressionSuggestion:
                "Break this expression up or add explicit type annotations. When one expression is this "
                + "expensive, the type-checker is usually exploring a blizzard of operator/overload "
                + "combinations — splitting it into intermediate `let`s with stated types collapses that work.",
            functionBodySuggestion:
                "Extract the heavy subexpressions into smaller helpers, or split this function. Every piece "
                + "the compiler can type-check on its own is one it doesn't have to solve all at once.",
            viewBodySuggestion:
                "This view body is carrying a lot of type-checking. Break it into smaller subviews or computed "
                + "properties so each piece type-checks independently; on recent SDKs the newer SwiftUI builders "
                + "also cut inference cost."))
}
