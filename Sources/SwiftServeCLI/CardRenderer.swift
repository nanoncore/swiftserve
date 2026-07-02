import Foundation
import SwiftServeCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Terminal capabilities

enum Terminal {
    static var isInteractive: Bool { isatty(STDOUT_FILENO) != 0 }
    static var colorEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil { return false }                 // NO_COLOR wins
        if let force = env["CLICOLOR_FORCE"], force != "0", !force.isEmpty { return true }
        return isInteractive
    }
}

enum Style {
    static func paint(_ s: String, _ code: String) -> String {
        Terminal.colorEnabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    static func bold(_ s: String) -> String { paint(s, "1") }
    static func dim(_ s: String) -> String { paint(s, "2") }
    static func green(_ s: String) -> String { paint(s, "32") }
    static func yellow(_ s: String) -> String { paint(s, "33") }
    static func red(_ s: String) -> String { paint(s, "31") }
    static func orange(_ s: String) -> String { paint(s, "38;5;208") }
}

// MARK: - Card

/// Render the same report the web card draws, as a calm terminal Scoop.
func renderCard(_ report: Report) -> String {
    let o = report.overall
    var lines: [String] = []

    lines.append("")
    lines.append("  \(moodEmoji(o.mood))  \(Style.bold(moodLabel(o.mood)))   \(paintScore(o.score))\(Style.dim("/100"))")
    lines.append("  \(Style.orange("“\(o.voiceLine)”"))")
    lines.append("  \(Style.dim(o.headline))")
    lines.append("")

    if report.packages.isEmpty {
        lines.append("  \(Style.dim("No dependencies to scan — nothing to melt."))")
        lines.append("")
    } else {
        let deps = report.packages.sorted { $0.score < $1.score } // worst first
        let nameW = min(30, max(10, deps.map { displayName($0).count }.max() ?? 10))
        let verW = min(18, max(7, deps.map { versionString($0).count }.max() ?? 7))

        lines.append("  " + Style.dim(
            rpad("SCORE", 6) + rpad("DEPENDENCY", nameW + 2) + rpad("VERSION", verW + 2) + "NOTE"))
        for p in deps {
            let score = paintScore(p.score, width: 5)
            let name = rpad(displayName(p), nameW + 2)
            let ver = Style.dim(rpad(versionString(p), verW + 2))
            lines.append("  \(score) \(name)\(ver)\(p.reason)")
        }
        lines.append("")
    }

    lines.append("  " + Style.dim(footer(report)))
    lines.append("")
    return lines.joined(separator: "\n")
}

// MARK: - Pieces

private func footer(_ report: Report) -> String {
    var parts = [
        "enrichment: \(report.enrichment.source)",
        "\(report.graph.total) deps",
    ]
    if !report.graph.duplicates.isEmpty {
        parts.append("\(report.graph.duplicates.count) duplicate name(s)")
    }
    parts.append("direct/transitive need the manifest")
    return parts.joined(separator: "  ·  ")
}

private func displayName(_ p: PackageReport) -> String { p.name }

private func versionString(_ p: PackageReport) -> String {
    let base: String
    if let v = p.resolvedVersion {
        base = v
    } else if p.pinType == .branch {
        base = "@\(p.branch ?? "branch")"
    } else if p.pinType == .revision {
        base = "commit"
    } else {
        base = "—"
    }
    if let latest = p.latestVersion, latest != p.resolvedVersion {
        return "\(base)→\(latest)"
    }
    return base
}

private func paintScore(_ score: Int, width: Int? = nil) -> String {
    let text = width.map { lpad("\(score)", $0) } ?? "\(score)"
    switch score {
    case 80...: return Style.green(text)
    case 55...: return Style.orange(text)
    case 30...: return Style.yellow(text)
    default: return Style.red(text)
    }
}

// moodEmoji(_:) is shared (defined in BinaryCardRenderer.swift).

private func moodLabel(_ m: Mood) -> String {
    switch m {
    case .partyMode: "PARTY MODE"
    case .freshSwirl: "FRESH SWIRL"
    case .softSqueeze: "SOFT SQUEEZE"
    case .meltdown: "MELTDOWN"
    case .dayOld: "DAY-OLD"
    case .idle: "IDLE"
    }
}

// MARK: - Padding (plain-width; ANSI is applied after)

private func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
private func lpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
