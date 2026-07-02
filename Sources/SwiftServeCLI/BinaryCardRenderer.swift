import Foundation
import SwiftServeCore
import SwiftServeScan

/// Render a `BinaryReport` as a calm terminal summary. Reuses `Terminal`/`Style`
/// (shared with the dependency-health card). Warm, never alarmist.
func renderBinaryCard(_ report: BinaryReport) -> String {
    var lines: [String] = [""]

    let v = report.swiftee
    lines.append("  \(moodEmoji(v.mood))  \(Style.bold(v.headline))")
    lines.append("  \(Style.orange("“\(v.voiceLine)”"))")
    lines.append("")

    if report.findings.isEmpty {
        lines.append("  \(Style.dim("No references to known private Apple symbols."))")
    } else {
        for f in report.findings {
            let sev = severityTag(f.severity)
            lines.append("  \(sev)  \(Style.bold(f.symbol))")

            var meta = [f.framework ?? "private API"]
            if let code = f.rejectionCode { meta.append(code) }
            meta.append("in \(f.origin.artifact ?? "?") (\(originLabel(f.origin.kind)))")
            lines.append("        \(Style.dim(meta.joined(separator: "  ·  ")))")

            lines.append("        \(f.explanation)")
            if let alt = f.alternative {
                lines.append("        \(Style.green("→ \(alt)"))")
            }
            lines.append("")
        }
    }

    if !report.warnings.isEmpty {
        lines.append("")
        for w in report.warnings { lines.append("  \(Style.dim("• \(w)"))") }
    }

    let archs = report.target.architectures.isEmpty ? "—" : report.target.architectures.joined(separator: ", ")
    let footer = "scanned \(report.target.binariesScanned.joined(separator: ", ")) (\(archs))  ·  denylist v\(report.denylist.version) (\(report.denylist.entryCount) entries)"
    lines.append("  \(Style.dim(footer))")
    lines.append("")
    return lines.joined(separator: "\n")
}

func severityTag(_ s: Severity) -> String {
    switch s {
    case .high: return Style.paint(" HIGH ", "41;1")   // white on red
    case .medium: return Style.paint(" MED  ", "43;30") // black on amber
    case .low: return Style.dim(" LOW  ")
    }
}

private func originLabel(_ k: OriginKind) -> String {
    switch k {
    case .firstParty: "first-party"
    case .dependency: "dependency"
    case .unattributed: "unattributed"
    }
}

func moodEmoji(_ m: Mood) -> String {
    switch m {
    case .partyMode: "🎉"
    case .freshSwirl: "😎"
    case .softSqueeze: "🍦"
    case .meltdown: "😟"
    case .dayOld: "😴"
    case .idle: "🍦"
    }
}
