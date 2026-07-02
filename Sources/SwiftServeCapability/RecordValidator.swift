import Foundation

/// The gate that makes LLM labeling trustworthy: every capability claim must
/// be grounded in the deterministic surface, or it dies here. Pure — surfaces
/// and taxonomy come in as data; nothing about how a record was produced
/// matters.
public enum RecordValidator {

    public struct Diagnostic: Sendable, Equatable {
        public enum Severity: String, Sendable { case error, warning }
        public let rule: String
        public let severity: Severity
        public let message: String
    }

    public struct ValidationResult: Sendable, Equatable {
        public let diagnostics: [Diagnostic]
        public var isAccepted: Bool { !diagnostics.contains { $0.severity == .error } }
        public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    }

    /// Confidence ceilings — the model may claim less, never more.
    public enum Caps {
        public static let absolute = 0.95        // there is no certainty in this business
        public static let conditionalOnly = 0.6  // all evidence resolves indeterminate
        public static let weakEvidenceOnly = 0.3 // readme/manifest-only claims
        public static let macroFlagged = 0.7     // anchored decl may be macro-generated
        public static let binaryBlindSpot = 0.8  // package ships binary targets (the Krisp lesson)
    }

    public static func validate(_ record: CapabilityRecord,
                                surfaces: [String: PackageSurface],
                                digests: [String: String] = [:],
                                taxonomy: Taxonomy) -> ValidationResult {
        var diagnostics: [Diagnostic] = []
        func error(_ rule: String, _ message: String) {
            diagnostics.append(Diagnostic(rule: rule, severity: .error, message: message))
        }
        func warning(_ rule: String, _ message: String) {
            diagnostics.append(Diagnostic(rule: rule, severity: .warning, message: message))
        }

        let home = record.package.canonicalURL
        guard let homeSurface = surfaces[home] else {
            error("V02", "no surface loaded for \(home) — fetch + extract it first")
            return ValidationResult(diagnostics: diagnostics)
        }

        // V01 — taxonomy membership.
        if !taxonomy.contains(record.capability.id) {
            error("V01", "capability ‘\(record.capability.id)’ is not in the \(taxonomy.domain) taxonomy — propose it there first")
        }

        // V06 — provenance: the record must describe the surface we actually have.
        if record.package.commit != (homeSurface.package.commit ?? "") {
            error("V06", "record pins commit \(record.package.commit.prefix(8)) but the surface is at \((homeSurface.package.commit ?? "?").prefix(8)) — re-extract or relabel")
        }
        if let expected = digests[home], record.package.surfaceDigest != expected {
            error("V06", "surfaceDigest mismatch for \(home) — the surface changed since labeling")
        }

        // Resolve every anchor once; V02 kills hallucinations.
        func decl(for anchor: EvidenceAnchor, rule: String, context: String) -> SurfaceDecl? {
            guard anchor.kind == .symbol || anchor.kind == .guard || anchor.kind == .availability else { return nil }
            let target = anchor.package ?? home
            guard let surface = surfaces[target] else {
                error(rule, "\(context): anchor cites \(target) but no surface is loaded for it")
                return nil
            }
            guard let symbol = anchor.symbol else {
                error("V02", "\(context): anchor has no symbol")
                return nil
            }
            let candidates = surface.decls.filter { $0.name == symbol }
            guard !candidates.isEmpty else {
                error("V02", "\(context): anchor symbol ‘\(symbol)’ does not exist on \(target)'s surface — hallucinated?")
                return nil
            }
            // Same-named decls are legal Swift (e.g. an os(macOS)/!os(macOS)
            // split pair) — the anchor's file+line picks the exact one.
            let match: SurfaceDecl
            if candidates.count == 1 {
                match = candidates[0]
            } else if let exact = candidates.first(where: {
                $0.location.file == anchor.file && $0.location.line == anchor.line
            }) {
                match = exact
            } else {
                error("V02", "\(context): ‘\(symbol)’ has \(candidates.count) declarations on \(target)'s surface — the anchor's file+line (\(anchor.file ?? "nil"):\(anchor.line.map(String.init) ?? "nil")) matches none of them")
                return nil
            }
            if let file = anchor.file, file != match.location.file {
                error("V02", "\(context): anchor file \(file) ≠ surface \(match.location.file) for \(symbol)")
                return nil
            }
            if let line = anchor.line, line != match.location.line {
                error("V02", "\(context): anchor line \(line) ≠ surface line \(match.location.line) for \(symbol)")
                return nil
            }
            return match
        }

        // Per-platform claims.
        for (platformKey, claim) in record.platforms.sorted(by: { $0.key < $1.key }) {
            let context = "\(record.capability.id) on \(platformKey)"

            // V07 — vocabulary.
            guard Platform(rawValue: platformKey) != nil else {
                error("V07", "\(context): ‘\(platformKey)’ is not a platform (use \(Platform.allCases.map(\.rawValue).joined(separator: "/")))")
                continue
            }

            let anchored = claim.evidence.compactMap { anchor in
                decl(for: anchor, rule: "V02", context: context).map { (anchor, $0) }
            }
            let presences = anchored.map { $0.1.resolvedPlatforms?[platformKey] }

            // V03 — supported needs a symbol provably present.
            if claim.status == .supported {
                let hasPresent = zip(anchored, presences).contains { pair, presence in
                    pair.0.kind == .symbol && presence == .present
                }
                if !hasPresent {
                    let hasConditional = presences.contains { if case .conditional = $0 { true } else { false } }
                    if hasConditional {
                        error("V03", "\(context): best evidence resolves CONDITIONAL — claim status ‘conditional’, not ‘supported’")
                    } else {
                        error("V03", "\(context): ‘supported’ needs a symbol anchor that resolves present on \(platformKey)")
                    }
                }
            }

            // V04 — unsupported needs a proven fence. Absence of symbols is
            // NOT evidence of absence; that's what ‘unknown’ is for.
            if claim.status == .unsupported {
                let hasFence = zip(anchored, presences).contains { pair, presence in
                    (pair.0.kind == .guard || pair.0.kind == .availability) && presence == .absent
                }
                if !hasFence {
                    error("V04", "\(context): ‘unsupported’ needs a guard/availability anchor that resolves absent on \(platformKey) — manifest platforms and symbol absence can never ground it (say ‘unknown’)")
                }
            }

            // V05 — confidence ceilings.
            var cap = Caps.absolute
            var capReason = "absolute ceiling"
            let strongAnchors = anchored.filter { $0.0.kind != .readme && $0.0.kind != .manifestPlatforms }
            if strongAnchors.isEmpty {
                cap = min(cap, Caps.weakEvidenceOnly)
                capReason = "readme/manifest-only evidence"
                if claim.status != .unknown {
                    error("V05", "\(context): with only readme/manifest evidence the status must be ‘unknown’")
                }
            } else {
                let allConditional = presences.allSatisfy { if case .conditional = $0 { true } else { false } }
                if allConditional, !presences.isEmpty {
                    cap = min(cap, Caps.conditionalOnly)
                    capReason = "all evidence resolves conditional"
                }
                if anchored.contains(where: { $0.1.hasMacroAttributes }) {
                    cap = min(cap, Caps.macroFlagged)
                    capReason = "anchored decl carries macro attributes"
                }
            }
            let anchorSurfaces = Set(anchored.compactMap { $0.0.package } + [home])
            if anchorSurfaces.contains(where: { surfaces[$0]?.stats.hasBinaryTargets == true }) {
                cap = min(cap, Caps.binaryBlindSpot)
                capReason = "package ships binary targets we can't parse"
            }
            if claim.confidence > cap {
                error("V05", "\(context): confidence \(claim.confidence) exceeds cap \(cap) (\(capReason))")
            }
            if claim.confidence < 0 {
                error("V07", "\(context): negative confidence")
            }
        }

        // W01 — coverage nudge, not a failure.
        let missing = Platform.allCases.map(\.rawValue).filter { record.platforms[$0] == nil }
        if !missing.isEmpty {
            warning("W01", "\(record.capability.id): no claim for \(missing.joined(separator: ", ")) — add them (‘unknown’ is a fine answer)")
        }

        return ValidationResult(diagnostics: diagnostics)
    }
}
