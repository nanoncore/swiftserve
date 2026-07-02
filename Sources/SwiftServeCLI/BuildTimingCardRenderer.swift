import Foundation
import SwiftServeBuild

/// Render a `BuildTimingReport` as a calm terminal summary: the headline first, then the
/// ranked pointers (most expensive first) with file:line and a concrete fix, then the
/// "+ M more" rollup. Reuses the shared `Style`/`Terminal` + `moodEmoji`. The tone is
/// encouraging — quick wins, not violations.
func renderBuildTimingCard(_ report: BuildTimingReport) -> String {
    var lines: [String] = [""]

    let v = report.swiftee
    lines.append("  \(moodEmoji(v.mood))  \(Style.bold(v.headline))")
    lines.append("  \(Style.orange("“\(v.voiceLine)”"))")
    lines.append("")

    if report.pointers.isEmpty {
        if report.summary.cachedBuild {
            lines.append("  \(Style.dim("Nothing recompiled, so there's little to measure — `--clean` forces a full build."))")
        } else {
            lines.append("  \(Style.dim("No expressions or function bodies crossed the timing thresholds."))")
        }
    } else {
        let detailed = report.pointers.prefix(report.summary.detailedCount)
        for p in detailed { lines += renderPointer(p) }

        if report.summary.rolledUpCount > 0 {
            let more = report.summary.rolledUpCount
            let combined = TimingAnalyzer.formatMs(report.summary.totalFlaggedMs - report.summary.topNRecoverableMs)
            lines.append("")
            lines.append("  \(Style.dim("+ \(more) more over threshold (~\(combined) combined) — see --json for the full list."))")
        }
    }

    if !report.warnings.isEmpty {
        lines.append("")
        for w in report.warnings { lines.append("  \(Style.dim("• \(w)"))") }
    }

    let cfg = report.config
    let where_ = report.target.mode == "log" ? "log \(report.target.path)" : "built \(report.target.path)"
    var footer = [where_,
                  "expr≥\(cfg.expressionThresholdMs)ms · body≥\(cfg.functionBodyThresholdMs)ms",
                  "\(report.summary.flaggedSiteCount) flagged"]
    if let total = report.summary.totalTypeCheckMs {
        footer.append("~\(TimingAnalyzer.formatMs(total)) type-check")
    }
    lines.append("  \(Style.dim(footer.joined(separator: "  ·  ")))")
    lines.append("")
    return lines.joined(separator: "\n")
}

private func renderPointer(_ p: Pointer) -> [String] {
    var out: [String] = [""]
    let cost = Style.bold(TimingAnalyzer.formatMs(p.costMs))
    out.append("  \(impactTag(p.impact))  \(cost)  \(Style.dim(categoryLabel(p.category)))")

    var meta = "\(p.location.file):\(p.location.line):\(p.location.column)"
    if let decl = p.decl { meta += "  ·  \(decl)" }
    out.append("        \(Style.dim(meta))")

    if let excerpt = p.excerpt { out.append("        \(Style.dim(excerpt))") }
    out.append("        \(p.explanation)")
    out.append("        \(Style.green("→ \(p.suggestion)"))")
    return out
}

private func categoryLabel(_ c: PointerCategory) -> String {
    switch c {
    case .slowExpression: "expression"
    case .slowFunctionBody: "function body"
    }
}

/// Impact tags, padded to a common width so the ranked list stays aligned.
private func impactTag(_ t: ImpactTier) -> String {
    switch t {
    case .critical: return Style.paint(" CRITICAL ", "41;1")    // white on red
    case .high: return Style.paint("   HIGH   ", "43;30")       // black on amber
    case .moderate: return Style.dim(" MODERATE ")
    }
}
