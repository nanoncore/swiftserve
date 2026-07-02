import Foundation

/// Which detection surface a finding came from. Binary/deps scans set `.binary`;
/// the source scan sets `.source`. One Finding vocabulary spans every pillar.
public enum Surface: String, Codable, Sendable, Equatable {
    case binary
    case source
}

/// How sure we are — source scanning only. Binary findings leave this nil: a linked
/// symbol is its own proof, and `severity` already carries the weight there.
///
/// - `high`        the string matches a known denylist entry — *definite*.
/// - `needsReview` it looks private by heuristic but isn't on the denylist —
///                 *possible*. A gentle heads-up, never a failure.
public enum Confidence: String, Codable, Sendable, Equatable {
    case high
    case needsReview
}

/// Which extractor produced a candidate — so an Objective-C regex "possible" reads
/// differently from a Swift-AST "possible". The AST one is genuinely more
/// trustworthy; the regex one can't prove context, so it never speaks with authority.
public enum SourceAnalyzer: String, Codable, Sendable, Equatable {
    case swiftSyntax    // parsed from a real Swift AST
    case objcHeuristic  // best-effort text patterns over Objective-C
}

/// Where in the source a candidate/finding sits. Source scanning's edge over binary
/// scanning is an exact location — so we surface file/line/column.
public struct SourceLocation: Codable, Sendable, Equatable {
    public let file: String
    public let line: Int
    public let column: Int
    public init(file: String, line: Int, column: Int) {
        self.file = file; self.line = line; self.column = column
    }
}

/// The dynamic-access pattern a candidate represents. Selects which denylist
/// `SymbolKind` it's matched against (when any), and shapes the explanation.
public enum SourceCallKind: String, Sendable, Equatable {
    case selector         // Selector("…"), NSSelectorFromString("…"), @selector(…)
    case classLookup      // NSClassFromString("…")
    case symbol           // dlsym(_, "…"), @_silgen_name("…"), @_cdecl("…")
    case kvcKey           // value(forKey:), setValue(_:forKey:), value(forKeyPath:)
    case dynamicLoadPath  // dlopen("…") / a path handed to the dynamic loader

    /// The denylist `SymbolKind` this maps to, when a denylist lookup makes sense.
    /// KVC keys and load paths have no natural symbol kind — they ride the
    /// heuristic / structural rules, not the denylist.
    public var symbolKind: SymbolKind? {
        switch self {
        case .selector: .objcSelector
        case .classLookup: .objcClass
        case .symbol: .importedSymbol
        case .kvcKey, .dynamicLoadPath: nil
        }
    }

    /// Human label for the access shape, used in generated explanations.
    public var noun: String {
        switch self {
        case .selector: "selector"
        case .classLookup: "class name"
        case .symbol: "symbol"
        case .kvcKey: "KVC key"
        case .dynamicLoadPath: "dynamic-load path"
        }
    }
}

/// The string argument we could actually read at a call site.
///
/// Confidence requires a literal we can read end-to-end. A constructed/interpolated
/// value can only ever be a heads-up, because we can't prove what it resolves to at
/// runtime — that's the literal-vs-constructed line that keeps `high` meaning high.
public enum ArgumentForm: Sendable, Equatable {
    case literal(String)        // one static string literal — fully readable
    case constructed([String])  // interpolation/concatenation — only some segments are literal

    /// The whole readable value, when the argument is a single literal.
    public var literalValue: String? {
        if case .literal(let s) = self { return s }
        return nil
    }

    /// Every literal text we can see (the whole string, or the literal segments of a
    /// constructed one). Used by the heuristic to spot a private-looking fragment.
    public var readableSegments: [String] {
        switch self {
        case .literal(let s): [s]
        case .constructed(let segs): segs
        }
    }
}

/// A dynamic-access site pulled out of source, *before* the privacy verdict. This is
/// the pure product of `SwiftServeSource`; it's the input to `SourceScanner` in this
/// module, which owns the "is this private" judgment for every surface.
public struct CandidateSite: Sendable, Equatable {
    public let kind: SourceCallKind
    public let api: String            // the call as it reads, e.g. "Selector(_:)" — for the explanation
    public let argument: ArgumentForm
    public let location: SourceLocation
    public let analyzer: SourceAnalyzer

    public init(kind: SourceCallKind, api: String, argument: ArgumentForm,
                location: SourceLocation, analyzer: SourceAnalyzer) {
        self.kind = kind; self.api = api; self.argument = argument
        self.location = location; self.analyzer = analyzer
    }
}
