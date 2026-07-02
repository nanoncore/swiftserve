import Foundation
import SwiftServeScan

/// Best-effort Objective-C scanning: simple text patterns over `.m`/`.h`, because ObjC
/// has no clean Swift-native AST. EVERYTHING it emits is `analyzer: .objcHeuristic`,
/// which `SourceScanner` caps at needs-review — regex can't prove a hit isn't inside a
/// comment or `#if 0`, so it never speaks with authority. Four obvious shapes only; the
/// moment this wants a real grammar, that's libclang and a later slice.
public enum ObjCHeuristicScanner {

    private struct Pattern {
        let kind: SourceCallKind
        let api: String
        let regex: NSRegularExpression
    }

    private static let patterns: [Pattern] = {
        func r(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            Pattern(kind: .selector, api: "@selector(…)",
                    regex: r(#"@selector\(\s*([A-Za-z_][A-Za-z0-9_:]*)\s*\)"#)),
            Pattern(kind: .selector, api: "NSSelectorFromString(…)",
                    regex: r(#"NSSelectorFromString\(\s*@"([^"]*)""#)),
            Pattern(kind: .classLookup, api: "NSClassFromString(…)",
                    regex: r(#"NSClassFromString\(\s*@"([^"]*)""#)),
            Pattern(kind: .kvcKey, api: "valueForKey:",
                    regex: r(#"forKey(?:Path)?:\s*@"([^"]*)""#)),
            Pattern(kind: .symbol, api: "dlsym",
                    regex: r(#"dlsym\([^,]*,\s*"([^"]*)""#)),
            Pattern(kind: .dynamicLoadPath, api: "dlopen",
                    regex: r(#"dlopen\(\s*"([^"]*)""#)),
        ]
    }()

    public static func candidates(in source: String, file: String) -> [CandidateSite] {
        var sites: [CandidateSite] = []
        var lineNo = 0
        source.enumerateLines { line, _ in
            lineNo += 1
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            for p in patterns {
                for m in p.regex.matches(in: line, range: full) where m.numberOfRanges >= 2 {
                    let capture = m.range(at: 1)
                    guard capture.location != NSNotFound, !ns.substring(with: capture).isEmpty else { continue }
                    sites.append(CandidateSite(
                        kind: p.kind, api: p.api, argument: .literal(ns.substring(with: capture)),
                        location: SourceLocation(file: file, line: lineNo, column: m.range.location + 1),
                        analyzer: .objcHeuristic))
                }
            }
        }
        return sites
    }
}
