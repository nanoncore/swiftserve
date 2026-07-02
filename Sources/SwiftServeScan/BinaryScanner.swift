import Foundation

/// The heart of Pillar 2: match extracted symbols against the denylist.
/// Pure and synchronous — no I/O, no process-spawning. Feed it data, get findings.
public enum BinaryScanner {

    public static func detect(_ symbols: [ExtractedSymbol], denylist: Denylist) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<String>()

        for symbol in symbols {
            let normalized = symbol.normalizedName
            for entry in denylist.entries where entry.appliesTo.contains(symbol.kind) {
                guard matches(normalized, entry: entry) else { continue }

                // One finding per (artifact, symbol, entry); first matching entry wins.
                let key = "\(symbol.origin.artifact ?? "")|\(symbol.kind.rawValue)|\(normalized)|\(entry.id)"
                if seen.insert(key).inserted {
                    findings.append(Finding(
                        symbol: normalized,
                        rawSymbol: symbol.name,
                        symbolKind: symbol.kind,
                        matchType: entry.match,
                        matchedPattern: entry.pattern,
                        framework: entry.framework,
                        severity: entry.severity,
                        explanation: entry.why,
                        rejectionCode: entry.rejectionCode,
                        alternative: entry.alternative,
                        reference: entry.reference,
                        origin: symbol.origin))
                }
                break
            }
        }

        // Worst first, then alphabetical — stable, attention where it's needed.
        return findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.symbol < $1.symbol
        }
    }

    private static func matches(_ name: String, entry: DenylistEntry) -> Bool {
        switch entry.match {
        case .exact: return name == entry.pattern
        case .prefix: return name.hasPrefix(entry.pattern)
        }
    }
}
