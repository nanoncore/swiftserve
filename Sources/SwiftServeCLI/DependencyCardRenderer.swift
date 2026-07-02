import Foundation
import SwiftServeScan

/// Render a `DependencyScanReport` grouped by origin so "mine vs theirs" is
/// obvious. A dependency's fault reads as relief, not a scolding.
func renderDependencyCard(_ report: DependencyScanReport) -> String {
    var lines: [String] = [""]

    let v = report.swiftee
    lines.append("  \(moodEmoji(v.mood))  \(Style.bold(v.headline))")
    lines.append("  \(Style.orange("“\(v.voiceLine)”"))")
    lines.append("")

    for rollup in report.dependencies {
        lines.append(contentsOf: renderGroup(rollup, findings: findings(for: rollup, in: report)))
    }

    if !report.warnings.isEmpty {
        lines.append("")
        for w in report.warnings { lines.append("  \(Style.dim("• \(w)"))") }
    }

    let scanned = report.dependencies.filter { $0.kind == .dependency && $0.status == .scanned }.count
    lines.append("  " + Style.dim("scanned \(scanned) dependency binar\(scanned == 1 ? "y" : "ies")  ·  denylist v\(report.denylist.version) (\(report.denylist.entryCount) entries)"))
    lines.append("")
    return lines.joined(separator: "\n")
}

private func findings(for rollup: DependencyRollup, in report: DependencyScanReport) -> [Finding] {
    report.findings.filter {
        switch rollup.kind {
        case .firstParty: $0.origin.kind == .firstParty
        case .dependency: $0.origin.dependency == rollup.identity
        case .unattributed: $0.origin.kind == .unattributed
        }
    }
}

private func renderGroup(_ rollup: DependencyRollup, findings: [Finding]) -> [String] {
    var out: [String] = []
    out.append("  \(groupHeader(rollup))")

    for f in findings {
        out.append("      \(severityTag(f.severity))  \(Style.bold(f.symbol))")
        var meta = [f.framework ?? "private API"]
        if let code = f.rejectionCode { meta.append(code) }
        out.append("            \(Style.dim(meta.joined(separator: "  ·  ")))")
        out.append("            \(f.explanation)")
        if let alt = f.alternative { out.append("            \(Style.green("→ \(alt)"))") }
    }

    // Relief copy when a dependency (not the user) is the one reaching into private API.
    if rollup.kind == .dependency, rollup.high > 0 {
        let who = "\(rollup.identity ?? "this dependency")\(rollup.version.map { " \($0)" } ?? "")"
        out.append("      \(Style.dim("Not on you — \(who) is reaching into a private API. Update it, swap it, or file upstream."))")
    }
    out.append("")
    return out
}

private func groupHeader(_ r: DependencyRollup) -> String {
    let title: String
    switch r.kind {
    case .firstParty: title = Style.bold("Your code")
    case .dependency: title = Style.bold(r.identity ?? "(dependency)") + (r.version.map { Style.dim(" \($0)") } ?? "")
    case .unattributed: title = Style.bold("Unattributed")
    }

    let status: String
    switch r.status {
    case .scanned:
        status = r.findingCount == 0
            ? Style.green("✓ clean")
            : "\(r.findingCount) issue\(r.findingCount == 1 ? "" : "s")" + (r.high > 0 ? Style.red("  (\(r.high) high)") : "")
    case .sourceOnly:
        status = Style.dim("source only — not scanned here")
    case .notBuilt:
        status = Style.dim("not built — build/resolve first")
    }
    return "\(title)  —  \(status)"
}
