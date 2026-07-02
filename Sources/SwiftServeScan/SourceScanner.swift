import Foundation

/// The "is this private" judgment for source candidates — the same one `BinaryScanner`
/// applies to symbols, sharing the same `Denylist`. Pure and synchronous: feed it
/// candidate sites, get `Finding`s. No SwiftSyntax, no I/O.
///
/// Confidence rules (the whole point — source is the most false-positive-prone surface):
///  - **high**        the readable literal matches a denylist entry, or is a literal
///                    path under `/System/Library/PrivateFrameworks/`. *Definite.*
///  - **needsReview** it looks private by heuristic (leading `_`, known prefix), or a
///                    *constructed* value contains a private-looking fragment. *Possible.*
///  - nothing         no evidence we can read. When unsure, we stay quiet.
///
/// Two caps keep `high` honest:
///  - a **constructed** argument is never `high` — we can't prove what it resolves to.
///  - an **Objective-C** candidate (regex, no AST) is never `high` — it can't prove context.
public enum SourceScanner {

    public static func detect(_ sites: [CandidateSite], denylist: Denylist,
                              heuristic: PrivacyHeuristic = .default) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<String>()

        for site in sites {
            guard let finding = evaluate(site, denylist: denylist, heuristic: heuristic) else { continue }
            // One finding per (file, line, column, symbol, confidence).
            let loc = finding.location
            let key = "\(loc?.file ?? "")|\(loc?.line ?? 0)|\(loc?.column ?? 0)|\(finding.symbol)|\(finding.confidence?.rawValue ?? "")"
            if seen.insert(key).inserted { findings.append(finding) }
        }

        // Definite before possible; then by file, then by line — stable, scannable.
        return findings.sorted { a, b in
            let ca = a.confidence == .high ? 0 : 1
            let cb = b.confidence == .high ? 0 : 1
            if ca != cb { return ca < cb }
            let fa = a.location?.file ?? "", fb = b.location?.file ?? ""
            if fa != fb { return fa < fb }
            return (a.location?.line ?? 0) < (b.location?.line ?? 0)
        }
    }

    // MARK: - One candidate → at most one finding

    private static func evaluate(_ site: CandidateSite, denylist: Denylist,
                                 heuristic: PrivacyHeuristic) -> Finding? {
        // ObjC (regex) findings can never be `high`: no AST means no proof of context.
        let canBeHigh = site.analyzer != .objcHeuristic

        switch site.argument {
        case .literal(let value):
            // 1. Denylist match on the whole literal → definite (capped for ObjC).
            if let kind = site.kind.symbolKind,
               let entry = denylistMatch(value, kind: kind, denylist: denylist) {
                return finding(for: site, value: value,
                               confidence: canBeHigh ? .high : .needsReview, entry: entry)
            }
            // 2. A literal path under /System/Library/PrivateFrameworks/ is structurally
            //    private — nobody points dlopen/dlsym there by accident.
            if site.kind == .dynamicLoadPath, isPrivateFrameworksPath(value) {
                return privateFrameworkFinding(for: site, value: value,
                                               confidence: canBeHigh ? .high : .needsReview)
            }
            // 3. Looks private by heuristic, but isn't on the denylist → possible.
            if heuristic.looksPrivate(value, kind: site.kind) {
                return heuristicFinding(for: site, value: value)
            }
            return nil

        case .constructed(let segments):
            // A constructed value can never be `high` — we can't read the whole string.
            // If any readable fragment looks private, raise a heads-up, nothing more.
            let flagged = segments.first { seg in
                seg.contains("/PrivateFrameworks/") || heuristic.looksPrivate(seg, kind: site.kind)
                    || site.kind.symbolKind.map { denylistMatch(seg, kind: $0, denylist: denylist) != nil } ?? false
            }
            guard let fragment = flagged else { return nil }
            return constructedFinding(for: site, fragment: fragment)
        }
    }

    // MARK: - Finding builders

    /// Definite: reuse the denylist entry's framework / why / alternative — the
    /// explanation layer is the product, same as the binary scan.
    private static func finding(for site: CandidateSite, value: String,
                                confidence: Confidence, entry: DenylistEntry) -> Finding {
        Finding(
            symbol: value, rawSymbol: value, symbolKind: site.kind.symbolKind,
            matchType: entry.match, matchedPattern: entry.pattern, framework: entry.framework,
            severity: entry.severity, explanation: entry.why,
            rejectionCode: entry.rejectionCode, alternative: entry.alternative, reference: entry.reference,
            origin: Origin(kind: .firstParty),
            surface: .source, confidence: confidence, location: site.location, analyzer: site.analyzer)
    }

    private static func privateFrameworkFinding(for site: CandidateSite, value: String,
                                                confidence: Confidence) -> Finding {
        Finding(
            symbol: value, rawSymbol: value, symbolKind: nil, matchType: nil, matchedPattern: nil,
            framework: privateFrameworkName(from: value) ?? "Private framework",
            severity: .high,
            explanation: "Dynamically loads a path under /System/Library/PrivateFrameworks/. "
                + "Linking or dlopen-ing a private framework is non-public API and a reliable App Review rejection.",
            rejectionCode: "ITMS-90338",
            alternative: "Use the public framework that exposes this capability, if one exists; otherwise drop the dependency on private internals.",
            reference: nil, origin: Origin(kind: .firstParty),
            surface: .source, confidence: confidence, location: site.location, analyzer: site.analyzer)
    }

    private static func heuristicFinding(for site: CandidateSite, value: String) -> Finding {
        Finding(
            symbol: value, rawSymbol: value, symbolKind: nil, matchType: nil, matchedPattern: nil,
            framework: nil, severity: .low,
            explanation: "This \(site.kind.noun) looks private (\(site.api)) but isn't on the denylist — "
                + "a possible private-API reference worth a quick check, not a confirmed rejection.",
            rejectionCode: nil, alternative: nil, reference: nil, origin: Origin(kind: .firstParty),
            surface: .source, confidence: .needsReview, location: site.location, analyzer: site.analyzer)
    }

    private static func constructedFinding(for site: CandidateSite, fragment: String) -> Finding {
        Finding(
            symbol: fragment, rawSymbol: fragment, symbolKind: nil, matchType: nil, matchedPattern: nil,
            framework: nil, severity: .low,
            explanation: "A \(site.kind.noun) built at runtime (\(site.api)) includes a private-looking fragment "
                + "“\(fragment)”. We can't resolve the full value, so this is a heads-up to verify, not a verdict.",
            rejectionCode: nil, alternative: nil, reference: nil, origin: Origin(kind: .firstParty),
            surface: .source, confidence: .needsReview, location: site.location, analyzer: site.analyzer)
    }

    // MARK: - Matching helpers

    /// Same exact/prefix matching as `BinaryScanner`, scoped to entries for this kind.
    private static func denylistMatch(_ value: String, kind: SymbolKind, denylist: Denylist) -> DenylistEntry? {
        denylist.entries.first { entry in
            guard entry.appliesTo.contains(kind) else { return false }
            switch entry.match {
            case .exact: return value == entry.pattern
            case .prefix: return value.hasPrefix(entry.pattern)
            }
        }
    }

    static func isPrivateFrameworksPath(_ s: String) -> Bool {
        s.contains("/System/Library/PrivateFrameworks/")
    }

    /// Pull "Foo" out of ".../PrivateFrameworks/Foo.framework/...".
    private static func privateFrameworkName(from path: String) -> String? {
        guard let range = path.range(of: "/PrivateFrameworks/") else { return nil }
        let tail = path[range.upperBound...]
        let name = tail.prefix { $0 != "/" }
        let trimmed = name.hasSuffix(".framework") ? String(name.dropLast(".framework".count)) : String(name)
        return trimmed.isEmpty ? nil : "\(trimmed) (private framework)"
    }
}

/// The "looks private" heuristic for needs-review findings. Deliberately conservative —
/// a leading underscore is the strongest generic signal; a small curated set of
/// framework prefixes catches private class names that aren't (yet) on the denylist.
/// Benign code (`value(forKey: "username")`) trips none of it.
public struct PrivacyHeuristic: Sendable, Equatable {
    /// Class-name prefixes that strongly imply a private framework class.
    public let privateClassPrefixes: [String]

    public init(privateClassPrefixes: [String]) {
        self.privateClassPrefixes = privateClassPrefixes
    }

    public static let `default` = PrivacyHeuristic(privateClassPrefixes: [
        "LSApplication", "SBS", "FBS", "BKS", "APS", "GSEvent", "UIKeyboardImpl",
        "FBSystem", "BoardServices", "_",
    ])

    public func looksPrivate(_ value: String, kind: SourceCallKind) -> Bool {
        guard !value.isEmpty else { return false }
        // The leading-underscore convention is the load-bearing signal everywhere.
        if value.hasPrefix("_") { return true }
        switch kind {
        case .classLookup:
            return privateClassPrefixes.contains { $0 != "_" && value.hasPrefix($0) }
        case .dynamicLoadPath:
            return value.contains("/PrivateFrameworks/")
        case .selector, .symbol, .kvcKey:
            return false
        }
    }
}
