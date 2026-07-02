import Foundation

/// Where in the source a slow-to-compile site sits. The entire value of a build-time
/// pointer is an exact jump target, so we always carry file:line:col.
///
/// This is *local* to the build pillar on purpose — it has nothing to do with the
/// private-API Scan surface, so it doesn't borrow that pillar's `SourceLocation`.
/// Keeping the seam clean is worth one tiny duplicated struct.
public struct CodeLocation: Codable, Sendable, Equatable {
    public let file: String
    public let line: Int
    public let column: Int
    public init(file: String, line: Int, column: Int) {
        self.file = file; self.line = line; self.column = column
    }
}

/// What kind of slow site a pointer describes. Deliberately open: dependency-cost and
/// other build-time pointers are the planned next expansion and slot in here without
/// reshaping the report.
public enum PointerCategory: String, Codable, Sendable, Equatable {
    case slowExpression    // one expression over the expression threshold
    case slowFunctionBody  // one function body over the body threshold
}

/// How much a single site is worth fixing, derived from its measured cost via the config
/// cutoffs. Tiers — not raw milliseconds — are what make a ranked list skimmable.
public enum ImpactTier: String, Codable, Sendable, Equatable {
    case critical  // the big rocks — fixing one is a visible build-time win
    case high
    case moderate  // over threshold, but a smaller win
}

/// One timing measurement parsed out of a build, *before* it becomes advice. The pure
/// product of `TimingParser`; the input to `TimingAnalyzer`. Tests build these directly.
public struct TimingRecord: Sendable, Equatable {
    public let category: PointerCategory
    public let location: CodeLocation
    public let costMs: Int
    public let limitMs: Int        // the limit the compiler reported crossing (0 if it didn't say)
    public let subject: String?    // a body's decl description ("getter for 'body'"); nil for a bare expression

    public init(category: PointerCategory, location: CodeLocation, costMs: Int, limitMs: Int, subject: String?) {
        self.category = category; self.location = location
        self.costMs = costMs; self.limitMs = limitMs; self.subject = subject
    }
}

/// A ranked, actionable build-time pointer — a *suggestion*, not a problem. This is the
/// product: an exact site, what it costs, how much it's worth fixing, and a concrete move.
/// Every optional field is encoded as explicit `null` for a stable, predictable schema —
/// same discipline as `Finding`.
public struct Pointer: Codable, Sendable, Equatable {
    public let category: PointerCategory
    public let location: CodeLocation
    public let costMs: Int
    public let thresholdMs: Int     // the configured threshold this site cleared
    public let impact: ImpactTier
    public let explanation: String  // plain-English why it's slow
    public let suggestion: String   // the concrete fix
    public let decl: String?        // the function decl, for bodies (nil for expressions)
    public let excerpt: String?     // a single source line, filled impurely by the CLI when readable

    public init(category: PointerCategory, location: CodeLocation, costMs: Int, thresholdMs: Int,
                impact: ImpactTier, explanation: String, suggestion: String,
                decl: String? = nil, excerpt: String? = nil) {
        self.category = category; self.location = location; self.costMs = costMs
        self.thresholdMs = thresholdMs; self.impact = impact; self.explanation = explanation
        self.suggestion = suggestion; self.decl = decl; self.excerpt = excerpt
    }

    /// A copy with an attached source excerpt. The CLI calls this after the pure analysis,
    /// once it has read the offending line off disk.
    public func withExcerpt(_ excerpt: String?) -> Pointer {
        Pointer(category: category, location: location, costMs: costMs, thresholdMs: thresholdMs,
                impact: impact, explanation: explanation, suggestion: suggestion,
                decl: decl, excerpt: excerpt)
    }

    enum CodingKeys: String, CodingKey {
        case category, location, costMs, thresholdMs, impact, explanation, suggestion, decl, excerpt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(category, forKey: .category)
        try c.encode(location, forKey: .location)
        try c.encode(costMs, forKey: .costMs)
        try c.encode(thresholdMs, forKey: .thresholdMs)
        try c.encode(impact, forKey: .impact)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(suggestion, forKey: .suggestion)
        try c.encode(decl, forKey: .decl)        // explicit null when absent
        try c.encode(excerpt, forKey: .excerpt)  // explicit null when absent
    }
}

/// Aggregate facts about the build the timings came from — the context the analyzer needs
/// to tell "cached, nothing recompiled" apart from "compiled clean, nothing slow", and to
/// anchor the headline against a true total. All measured impurely by the CLI and passed
/// in, so the verdict logic stays pure and unit-testable with no real build.
public struct BuildContext: Sendable, Equatable {
    /// Did the build itself complete? `false` is handled at the CLI layer (it reports the
    /// failure and emits no pointers) — the analyzer never sees a failed build.
    public let buildSucceeded: Bool
    /// How many files the build actually compiled. `0` in build mode ⇒ a cached/incremental
    /// build with little to measure. `nil` ⇒ unknown (log-ingest mode).
    public let compiledUnits: Int?
    /// Total type-check wall time from `-stats-output-dir`, when parseable. Anchors the
    /// "~X of ~Y" headline; `nil` falls back to summing the flagged sites.
    public let totalTypeCheckMs: Int?
    public let source: Source

    public enum Source: String, Sendable, Equatable {
        case build  // we drove `swift build`
        case log    // we ingested a build log the user already produced
    }

    public init(buildSucceeded: Bool, compiledUnits: Int?, totalTypeCheckMs: Int?, source: Source) {
        self.buildSucceeded = buildSucceeded; self.compiledUnits = compiledUnits
        self.totalTypeCheckMs = totalTypeCheckMs; self.source = source
    }

    /// True when we drove a build that recompiled nothing — the warnings only appear for
    /// files that actually recompiled, so this is the "looks cached" signal.
    public var looksCached: Bool { source == .build && compiledUnits == 0 }
}
