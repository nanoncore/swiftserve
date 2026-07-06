import Foundation

/// The gate that makes LLM labeling trustworthy: every capability claim must
/// be grounded in the deterministic surface, or it dies here. Pure — surfaces
/// and taxonomy come in as data; nothing about how a record was produced
/// matters.
public enum RecordValidator {

    public struct Diagnostic: Sendable, Equatable, Codable {
        public enum Severity: String, Sendable, Codable { case error, warning }
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
                                buildVerdicts: [String: BuildVerdict] = [:],
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

        // Resolve every anchor once via the shared resolver; V02 kills
        // hallucinations. Message strings are part of the contract — tests
        // assert on them.
        func decl(for anchor: EvidenceAnchor, rule: String, context: String) -> SurfaceDecl? {
            let target = anchor.package ?? home
            switch AnchorResolver.resolve(anchor, home: home, surfaces: surfaces) {
            case .success(let match):
                return match
            case .failure(.notResolvable):
                break // weak kinds name no decl — nothing to diagnose
            case .failure(.noSurface(let cited)):
                error(rule, "\(context): anchor cites \(cited) but no surface is loaded for it")
            case .failure(.noSymbol):
                error("V02", "\(context): anchor has no symbol")
            case .failure(.symbolMissing(let symbol)):
                error("V02", "\(context): anchor symbol ‘\(symbol)’ does not exist on \(target)'s surface — hallucinated?")
            case .failure(.ambiguous(let symbol, let count)):
                error("V02", "\(context): ‘\(symbol)’ has \(count) declarations on \(target)'s surface — the anchor's file+line (\(anchor.file ?? "nil"):\(anchor.line.map(String.init) ?? "nil")) matches none of them")
            case .failure(.fileMismatch(let anchorFile, let surfaceFile)):
                error("V02", "\(context): anchor file \(anchorFile) ≠ surface \(surfaceFile) for \(anchor.symbol ?? "?")")
            case .failure(.lineMismatch(let anchorLine, let surfaceLine)):
                error("V02", "\(context): anchor line \(anchorLine) ≠ surface line \(surfaceLine) for \(anchor.symbol ?? "?")")
            }
            return nil
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

            // V08 — buildVerdict anchors must cite a real, matching probe.
            // The anchor names no file; (home package, claim platform) locates
            // the verdict, and commit + outcome must agree with the record.
            var resolvedBuilds: [BuildVerdict] = []
            for anchor in claim.evidence where anchor.kind == .buildVerdict {
                if let target = anchor.package, target != home {
                    error("V08", "\(context): buildVerdict anchors ground the home package only — \(target) needs its own record")
                    continue
                }
                guard let verdict = buildVerdicts[BuildVerdict.key(canonicalURL: home, platform: platformKey)] else {
                    error("V08", "\(context): anchor cites a build verdict but none is loaded for \(home) on \(platformKey) — run `index build-probe` first")
                    continue
                }
                if verdict.commit != record.package.commit {
                    error("V08", "\(context): build verdict is for commit \(verdict.commit.prefix(8)) but the record pins \(record.package.commit.prefix(8)) — re-probe")
                    continue
                }
                if verdict.outcome == .inconclusive {
                    error("V08", "\(context): the build probe was inconclusive (\(verdict.errorExcerpt.first ?? "no detail")) — it grounds nothing; re-probe")
                    continue
                }
                if verdict.outcome == .failed, claim.status == .supported || claim.status == .conditional {
                    error("V08", "\(context): the package does not compile for \(platformKey) — ‘\(claim.status.rawValue)’ contradicts the build verdict")
                    continue
                }
                resolvedBuilds.append(verdict)
            }

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

            // V04 — unsupported needs a proven fence: a guard/availability
            // anchor that resolves absent, or a failed build verdict (the
            // package provably doesn't compile there). Absence of symbols is
            // NOT evidence of absence; that's what ‘unknown’ is for.
            if claim.status == .unsupported {
                let hasFence = zip(anchored, presences).contains { pair, presence in
                    (pair.0.kind == .guard || pair.0.kind == .availability) && presence == .absent
                }
                let hasFailedBuild = resolvedBuilds.contains { $0.outcome == .failed }
                if !hasFence && !hasFailedBuild {
                    error("V04", "\(context): ‘unsupported’ needs a guard/availability anchor that resolves absent on \(platformKey), or a failed build verdict — manifest platforms and symbol absence can never ground it (say ‘unknown’)")
                }
            }

            // V05 — confidence ceilings.
            var cap = Caps.absolute
            var capReason = "absolute ceiling"
            let strongAnchors = anchored.filter { $0.0.kind != .readme && $0.0.kind != .manifestPlatforms }
            if strongAnchors.isEmpty && !resolvedBuilds.isEmpty {
                // A build verdict is whole-package proof — strong on its own
                // (grounds ‘unsupported’ via V04; ‘supported’ still needs a
                // present symbol through V03).
            } else if strongAnchors.isEmpty {
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
