import Foundation
import SwiftServeCore
import SwiftServeScan

/// Render a `SourceScanReport` as a calm terminal summary, grouped by confidence —
/// definite first, possible below — each with an exact file:line:column so the user can
/// jump straight there. Reuses the shared `Style`/`Terminal` + `moodEmoji`.
func renderSourceCard(_ report: SourceScanReport) -> String {
    var lines: [String] = [""]

    let v = report.swiftee
    lines.append("  \(moodEmoji(v.mood))  \(Style.bold(v.headline))")
    lines.append("  \(Style.orange("“\(v.voiceLine)”"))")
    lines.append("")

    if report.findings.isEmpty {
        lines.append("  \(Style.dim("No dynamic private-API access patterns in source."))")
    } else {
        let definite = report.findings.filter { $0.confidence == .high }
        let possible = report.findings.filter { $0.confidence == .needsReview }
        if !definite.isEmpty {
            lines.append("  \(Style.bold("DEFINITE")) \(Style.dim("— references a known private API"))")
            for f in definite { lines += renderSourceFinding(f) }
        }
        if !possible.isEmpty {
            if !definite.isEmpty { lines.append("") }
            lines.append("  \(Style.bold("POSSIBLE")) \(Style.dim("— looks private; worth a look, not a failure"))")
            for f in possible { lines += renderSourceFinding(f) }
        }
    }

    if !report.warnings.isEmpty {
        lines.append("")
        for w in report.warnings { lines.append("  \(Style.dim("• \(w)"))") }
    }

    let t = report.target
    let footer = "scanned \(t.filesScanned) file\(t.filesScanned == 1 ? "" : "s") "
        + "(\(t.swiftFiles) swift, \(t.objcFiles) objc)  ·  "
        + "denylist v\(report.denylist.version) (\(report.denylist.entryCount) entries)"
    lines.append("  \(Style.dim(footer))")
    lines.append("")
    return lines.joined(separator: "\n")
}

private func renderSourceFinding(_ f: Finding) -> [String] {
    var out: [String] = [""]
    out.append("  \(confidenceTag(f.confidence))  \(Style.bold(f.symbol))")

    var meta: [String] = []
    if let fw = f.framework { meta.append(fw) }
    if let code = f.rejectionCode { meta.append(code) }
    if f.analyzer == .objcHeuristic { meta.append("heuristic · ObjC") }
    if let loc = f.location { meta.append("\(loc.file):\(loc.line):\(loc.column)") }
    out.append("        \(Style.dim(meta.joined(separator: "  ·  ")))")

    out.append("        \(f.explanation)")
    if let alt = f.alternative { out.append("        \(Style.green("→ \(alt)"))") }
    return out
}

private func confidenceTag(_ c: Confidence?) -> String {
    switch c {
    case .high: return Style.paint(" DEFINITE ", "41;1")    // white on red
    case .needsReview: return Style.paint(" POSSIBLE ", "43;30") // black on amber
    case nil: return Style.dim(" ? ")
    }
}
