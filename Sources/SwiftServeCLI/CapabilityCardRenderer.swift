import Foundation
import SwiftServeCapability

// Terminal cards for capability verdicts — rendered from the same canonical
// JSON agents read. Voice rules: the mood is the USER's situation, verdicts
// are version-pinned facts, and no package is ever scolded.

func renderCapabilityCard(_ report: CheckReport) -> String {
    var lines: [String] = []
    lines.append("")
    lines.append("  \(moodEmoji(report.swiftee.mood))  \(Style.bold(statusWord(report.verdict.status)))"
        + "   \(Style.dim("\(report.query.capabilityLabel) · \(report.query.platform) · as of \(report.verdict.version)"))")
    lines.append("  \(Style.orange("“\(report.swiftee.voiceLine)”"))")
    lines.append("  \(Style.dim(report.swiftee.headline))")
    lines.append("")

    if !report.evidence.isEmpty {
        lines.append("  \(Style.bold("The receipt"))")
        for item in report.evidence.prefix(4) {
            let head = [item.symbol, item.condition.map { "#if \($0)" }].compactMap(\.self).joined(separator: "  —  ")
            if !head.isEmpty { lines.append("    \(head)") }
            if let file = item.file, let line = item.line {
                lines.append(Style.dim("    \(file):\(line)"))
            }
            if let permalink = item.permalink {
                lines.append(Style.dim("    \(permalink)"))
            }
            if let note = item.note {
                lines.append(Style.dim("    \(note)"))
            }
        }
        lines.append("")
    }

    let served = report.otherPlatforms.filter { $0.value == "supported" }.keys.sorted()
    if report.verdict.status != .supported, !served.isEmpty {
        lines.append("  Served on: \(Style.green(served.joined(separator: ", ")))")
    }
    if !report.alternatives.isEmpty {
        let names = report.alternatives.prefix(3).map(\.packageName).joined(separator: ", ")
        lines.append("  Also serves it on \(report.query.platform): \(Style.green(names))")
    }
    if !report.requiresCompanion.isEmpty {
        lines.append(Style.dim("  Companion needed: \(report.requiresCompanion.joined(separator: ", "))"))
    }
    if let notes = report.notes {
        lines.append("")
        lines.append(Style.dim("  \(notes)"))
    }
    lines.append("")
    lines.append(Style.dim("  confidence \(String(format: "%.2f", report.verdict.confidence)) · commit \(report.verdict.commit.prefix(8)) · swiftserve capability-check"))
    return lines.joined(separator: "\n")
}

func renderFindCard(_ report: CapabilityQuery.FindReport) -> String {
    var lines: [String] = []
    lines.append("")
    lines.append("  🍦 \(Style.bold("\(report.capabilityLabel) on \(report.platform)"))"
        + Style.dim("   \(report.indexedPackages) package\(report.indexedPackages == 1 ? "" : "s") indexed"))
    lines.append("")
    if report.results.isEmpty {
        lines.append("  Nothing on the menu for that — yet.")
        lines.append(Style.dim("  An ‘unknown’ here is a gap in the index, not a verdict about the ecosystem."))
    } else {
        for row in report.results {
            let mark: String
            switch row.status {
            case .supported: mark = Style.green("✓")
            case .conditional: mark = Style.yellow("◐")
            case .unknown: mark = Style.dim("?")
            case .unsupported: mark = Style.red("✕")
            }
            let confidence = row.status == .unknown ? "" : Style.dim("  \(String(format: "%.2f", row.confidence))")
            lines.append("  \(mark) \(row.packageName.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + Style.dim("as of \(row.version)") + confidence)
        }
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

private func statusWord(_ status: ClaimStatus) -> String {
    switch status {
    case .supported: "Serves it"
    case .conditional: "Serves it — with conditions"
    case .unsupported: "Not served here"
    case .unknown: "Not verified yet"
    }
}
