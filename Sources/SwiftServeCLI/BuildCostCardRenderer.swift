import Foundation
import SwiftServeBuild

/// Render a `BuildCostReport` as a calm terminal card: the headline, then your targets (slowest
/// flagged), then dependency packages ranked by share with their health, then any rollup. Costs
/// are shown as share-of-build percentages — never seconds — because frontend work is parallel.
func renderBuildCostCard(_ report: BuildCostReport, detailedDeps: Int) -> String {
    var lines: [String] = [""]

    let v = report.swiftee
    lines.append("  \(moodEmoji(v.mood))  \(Style.bold(v.headline))")
    lines.append("  \(Style.orange("“\(v.voiceLine)”"))")
    lines.append("")

    if report.summary.cachedBuild {
        lines.append("  \(Style.dim("Nothing recompiled, so there's little to measure — `--clean` forces a full build."))")
    } else if report.entries.isEmpty {
        lines.append("  \(Style.dim("No compile cost to measure."))")
    } else {
        let targets = report.entries.filter { $0.origin == .yourTarget }
        let deps = report.entries.filter { $0.origin == .dependency }
        let unattributed = report.entries.filter { $0.origin == .unattributed }

        if !targets.isEmpty {
            lines.append("  \(Style.dim("YOUR TARGETS"))")
            for e in targets.prefix(detailedDeps) { lines.append(renderEntry(e)) }
            lines += rollup(targets, shown: detailedDeps, noun: "target")
        }

        if !deps.isEmpty {
            lines.append("")
            lines.append("  \(Style.dim("DEPENDENCIES"))")
            for e in deps.prefix(detailedDeps) { lines.append(renderEntry(e)) }
            lines += rollup(deps, shown: detailedDeps, noun: "dependency", plural: "dependencies")
        }

        for e in unattributed {
            lines.append("")
            lines.append("  " + share(e.sharePercent) + "  " + Style.dim("(unattributed) — \(e.moduleCount) module\(e.moduleCount == 1 ? "" : "s") we couldn't map"))
        }
    }

    if !report.warnings.isEmpty {
        lines.append("")
        for w in report.warnings { lines.append("  \(Style.dim("• \(w)"))") }
    }

    lines.append("")
    var footer = [report.target.mode == "build" ? "built \(report.target.path)" : "stats \(report.target.path)",
                  "~\(TimingAnalyzer.formatMs(report.summary.totalFrontendWallMs)) compile work",
                  "\(report.summary.dependencyCount) deps",
                  "share of build"]
    if !report.summary.healthCrossed { footer.append("no health (no Package.resolved)") }
    lines.append("  \(Style.dim(footer.joined(separator: "  ·  ")))")
    lines.append("")
    return lines.joined(separator: "\n")
}

private func renderEntry(_ e: BuildCostEntry) -> String {
    var row = "  " + share(e.sharePercent) + "  " + rpadCost(e.name, 24)
    if e.origin == .dependency {
        row += Style.dim(rpadCost(e.packageVersion ?? "—", 12))
        if let h = e.healthScore { row += healthBadge(h) }
    }
    if e.highlight == .slowestTarget {
        row += "  " + Style.yellow("← slowest target to compile")
    } else if e.highlight == .expensiveAndUnhealthy {
        let why = e.healthFlags.isEmpty ? "" : " (\(e.healthFlags.prefix(2).joined(separator: ", ")))"
        row += "  " + Style.paint(" expensive + unhealthy ", "43;30") + Style.dim(why)
    }
    return row
}

/// "+ N smaller <noun>s (X%)" when a section was capped.
private func rollup(_ all: [BuildCostEntry], shown: Int, noun: String, plural: String? = nil) -> [String] {
    guard all.count > shown else { return [] }
    let rest = all.suffix(all.count - shown)
    let pct = rest.reduce(0.0) { $0 + $1.sharePercent }
    let label = all.count - shown == 1 ? noun : (plural ?? noun + "s")
    return ["  " + Style.dim("+ \(all.count - shown) smaller \(label) (\(BuildCostAnalyzer.formatShare(pct)))")]
}

private func share(_ pct: Double) -> String {
    lpadCost(BuildCostAnalyzer.formatShare(pct), 6)
}

/// Health badge: "health 82" tinted by band, with a ✓ for healthy or a · marker otherwise.
private func healthBadge(_ score: Int) -> String {
    let text = "health \(score)"
    let painted: String
    switch score {
    case 80...: painted = Style.green(text)
    case 55...: painted = Style.orange(text)
    case 30...: painted = Style.yellow(text)
    default: painted = Style.red(text)
    }
    return painted + (score >= 80 ? " ✓" : "")
}

// Plain-width padding (ANSI applied after, so widths stay honest).
private func rpadCost(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
private func lpadCost(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
