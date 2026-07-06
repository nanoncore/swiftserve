import Foundation

/// Resolves an `EvidenceAnchor` to the one `SurfaceDecl` it names — the
/// single source of truth for anchor semantics, shared by the validator
/// (where a failure is a V02 diagnostic) and the recheck engine (where a
/// failure is a repair candidate or an anchor-gone verdict).
public enum AnchorResolver {

    /// Why an anchor failed to resolve. Carries only what the caller can't
    /// recompute from the anchor itself.
    public enum Failure: Error, Sendable, Equatable {
        /// The anchor kind names no declaration (readme, manifestPlatforms,
        /// buildVerdict) — not an error, just nothing to resolve.
        case notResolvable
        /// The cited surface (companion or home) isn't loaded.
        case noSurface(String)
        /// A resolvable kind with no symbol to look up.
        case noSymbol
        /// The symbol exists nowhere on the target surface.
        case symbolMissing(String)
        /// Same-named decls exist but the anchor's file+line matches none.
        case ambiguous(symbol: String, count: Int)
        /// A unique candidate exists, but not in the anchor's file.
        case fileMismatch(anchor: String, surface: String)
        /// Right file, wrong line — the decl moved.
        case lineMismatch(anchor: Int, surface: Int)
    }

    /// Exact-match semantics: filter by qualified name; same-named decls are
    /// legal Swift (e.g. an os(macOS)/!os(macOS) split pair), so the anchor's
    /// file+line picks the exact one; any file/line drift is a failure — the
    /// caller decides whether drift is fatal (validator) or repairable
    /// (recheck).
    public static func resolve(_ anchor: EvidenceAnchor, home: String,
                               surfaces: [String: PackageSurface]) -> Result<SurfaceDecl, Failure> {
        guard anchor.kind == .symbol || anchor.kind == .guard || anchor.kind == .availability else {
            return .failure(.notResolvable)
        }
        let target = anchor.package ?? home
        guard let surface = surfaces[target] else {
            return .failure(.noSurface(target))
        }
        guard let symbol = anchor.symbol else {
            return .failure(.noSymbol)
        }
        let candidates = surface.decls.filter { $0.name == symbol }
        guard !candidates.isEmpty else {
            return .failure(.symbolMissing(symbol))
        }
        let match: SurfaceDecl
        if candidates.count == 1 {
            match = candidates[0]
        } else if let exact = candidates.first(where: {
            $0.location.file == anchor.file && $0.location.line == anchor.line
        }) {
            match = exact
        } else {
            return .failure(.ambiguous(symbol: symbol, count: candidates.count))
        }
        if let file = anchor.file, file != match.location.file {
            return .failure(.fileMismatch(anchor: file, surface: match.location.file))
        }
        if let line = anchor.line, line != match.location.line {
            return .failure(.lineMismatch(anchor: line, surface: match.location.line))
        }
        return .success(match)
    }
}
