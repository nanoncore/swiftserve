import Foundation

public enum UpgradeReceiptMarkdownRenderer {
    public static func render(_ receipt: UpgradeReceipt) -> String {
        var lines = [
            "## 🍦 Upgrade Receipt — \(receipt.verdict.rawValue.uppercased())",
            "",
            receipt.headline,
            "",
            "| Package | Before | After | Classification | Severity |",
            "|---|---:|---:|---|---|",
        ]
        if receipt.changes.isEmpty {
            lines.append("| _No dependency changes_ | — | — | — | info |")
        } else {
            for change in receipt.changes {
                lines.append("| \(inlineCode(change.identity, tableCell: true)) | \(inlineCode(pinLabel(change.oldPin), tableCell: true)) | \(inlineCode(pinLabel(change.newPin), tableCell: true)) | \(change.classification.rawValue) | **\(change.severity.rawValue)** |")
            }
        }
        let findings = receipt.changes.flatMap(\.findings).filter { $0.severity >= .review }
        if !findings.isEmpty {
            lines += ["", "### Findings", ""]
            for finding in findings {
                lines.append("- **\(finding.severity.rawValue)** `\(finding.code.rawValue)` — \(escapeProse(finding.message))")
            }
        }
        if !receipt.policy.violations.isEmpty {
            lines += ["", "### Policy violations", ""]
            for violation in receipt.policy.violations {
                lines.append("- \(inlineCode(violation))")
            }
        }
        lines += [
            "", "Policy: \(inlineCode(receipt.policy.source)) · \(receipt.policy.passed ? "passed" : "needs attention")",
            "", "> A `pass` means no configured policy was violated. It is not a universal safety guarantee and does not replace compiling or tests.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func pinLabel(_ pin: PinSnapshot?) -> String {
        guard let pin else { return "—" }
        switch pin.pinType {
        case .version: return pin.version ?? "unknown"
        case .branch: return "branch:\(pin.branch ?? "unknown")"
        case .revision: return "revision:\(pin.revision.map { String($0.prefix(8)) } ?? "unknown")"
        case .unknown: return "unknown"
        }
    }

    /// A code span fence must be longer than every backtick run in untrusted
    /// content. Table pipes stay escaped even inside spans because GFM parses
    /// the table structure before rendering inline code.
    private static func inlineCode(_ rawValue: String, tableCell: Bool = false) -> String {
        var value = singleLine(rawValue)
        if tableCell {
            value = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
        }

        var longestRun = 0
        var currentRun = 0
        for character in value {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(1, longestRun + 1))
        let needsPadding = value.first == "`" || value.last == "`"
            || value.first == " " || value.last == " "
        let content = needsPadding ? " \(value) " : value
        return fence + content + fence
    }

    /// Finding messages sit in prose, so neutralize block boundaries, inline
    /// Markdown, raw HTML, entities, and GitHub mentions without hiding text.
    private static func escapeProse(_ rawValue: String) -> String {
        var result = ""
        for character in singleLine(rawValue) {
            switch character {
            case "\\": result += "\\\\"
            case "`": result += "\\`"
            case "*": result += "\\*"
            case "_": result += "\\_"
            case "[": result += "\\["
            case "]": result += "\\]"
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "@": result += "&#64;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func singleLine(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
    }
}
