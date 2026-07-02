import Foundation
import SwiftServeCapability

/// Static SVG badges — the growth loop. The badge is the *author's* asset:
/// it shows what a package serves and stays quiet about the rest (unsupported
/// renders as a muted dash, never a red ✕ — red-precision lives on the site;
/// nobody embeds red X's in their own README). Every badge links back to a
/// truth table.
public enum BadgeSVG {

    // Palette: the site tokens, verbatim.
    static let ink = "#2c2724"
    static let cream = "#fbf7f0"
    static let good = "#5fb37a"
    static let warn = "#e0a23a"
    static let quiet = "#a49a8f"       // unsupported/unknown — muted, not alarming
    static let accentDeep = "#d9742a"

    static let platformAbbrev: [(Platform, String)] = [
        (.iOS, "iOS"), (.macOS, "mac"), (.watchOS, "watch"), (.tvOS, "tv"),
        (.visionOS, "vis"), (.linux, "linux"), (.macCatalyst, "cat"),
    ]

    /// Rough Verdana-11 width estimation, shields.io-style (no font metrics
    /// at generation time; badges tolerate a pixel or two).
    static func textWidth(_ s: String) -> Double {
        s.reduce(0) { total, ch in
            if ch.isUppercase || ch.isNumber { return total + 7.2 }
            if "iljtf.".contains(ch) { return total + 3.4 }
            if "mw".contains(ch) { return total + 10.0 }
            return total + 6.3
        }
    }

    /// The minimal vector cone mark (emoji is unreliable inside README <img> SVGs).
    static func coneMark(x: Double, y: Double) -> String {
        """
        <g transform="translate(\(x),\(y)) scale(0.6)">
          <path d="M3 8 L8 18 L13 8 Z" fill="#e8b04b"/>
          <path d="M2.5 8 A5.5 5.5 0 0 1 13.5 8 Z" fill="#ed8b3e"/>
          <circle cx="8" cy="4.5" r="3.4" fill="#ed8b3e"/>
        </g>
        """
    }

    /// One-capability strip: [🍦 label][iOS][mac][watch]…
    public static func strip(record: CapabilityRecord) -> String {
        let label = record.capability.label
        let leftWidth = 24 + textWidth(label) + 8

        var segments = ""
        var x = leftWidth
        for (platform, abbrev) in platformAbbrev {
            let claim = record.platforms[platform.rawValue]
            let (fill, mark): (String, String)
            switch claim?.status {
            case .supported: (fill, mark) = (good, abbrev)
            case .conditional: (fill, mark) = (warn, abbrev)
            case .unsupported: (fill, mark) = (quiet, "–")
            case .unknown, nil: (fill, mark) = (quiet, "?")
            }
            let text = claim?.status == .unsupported || claim?.status == .unknown || claim == nil ? mark : abbrev
            let width = max(textWidth(text) + 12, 24)
            segments += """
            <rect x="\(f(x))" width="\(f(width))" height="20" fill="\(fill)"/>
            <text x="\(f(x + width / 2))" y="14" text-anchor="middle" fill="#fff" \
            font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="10.5">\(Html.escape(text))</text>
            """
            x += width
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(x))" height="20" role="img" aria-label="\(Html.escape(label)) platform support — SwiftServe">
          <title>\(Html.escape(label)) — verified by SwiftServe</title>
          <clipPath id="r"><rect width="\(f(x))" height="20" rx="4"/></clipPath>
          <g clip-path="url(#r)">
            <rect width="\(f(leftWidth))" height="20" fill="\(ink)"/>
            \(coneMark(x: 5, y: 3))
            <text x="22" y="14" fill="\(cream)" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">\(Html.escape(label))</text>
            \(segments)
          </g>
        </svg>
        """
    }

    /// Compact "verified" badge: [🍦 swiftserve][N capabilities verified]
    public static func verified(package: PackageView) -> String {
        let right = "\(package.records.count) capabilit\(package.records.count == 1 ? "y" : "ies") verified"
        let leftWidth = 24.0 + textWidth("swiftserve") + 8
        let rightWidth = textWidth(right) + 14
        let total = leftWidth + rightWidth
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(total))" height="20" role="img" aria-label="\(Html.escape(right)) — SwiftServe">
          <title>\(Html.escape(package.name)): \(Html.escape(right))</title>
          <clipPath id="r"><rect width="\(f(total))" height="20" rx="4"/></clipPath>
          <g clip-path="url(#r)">
            <rect width="\(f(leftWidth))" height="20" fill="\(ink)"/>
            \(coneMark(x: 5, y: 3))
            <text x="22" y="14" fill="\(cream)" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">swiftserve</text>
            <rect x="\(f(leftWidth))" width="\(f(rightWidth))" height="20" fill="\(accentDeep)"/>
            <text x="\(f(leftWidth + rightWidth / 2))" y="14" text-anchor="middle" fill="#fff" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">\(Html.escape(right))</text>
          </g>
        </svg>
        """
    }

    /// The README hero: the package's full capability × platform matrix.
    public static func matrix(package: PackageView) -> String {
        let rowHeight = 22.0
        let headerHeight = 26.0
        let labelWidth = max(package.records.map { textWidth($0.capability.label) }.max() ?? 60, 60) + 30
        let cellWidth = 44.0
        let width = labelWidth + cellWidth * Double(platformAbbrev.count)
        let height = headerHeight + rowHeight * Double(package.records.count) + 6

        var body = ""
        // Header row: platform abbreviations.
        for (index, (_, abbrev)) in platformAbbrev.enumerated() {
            let cx = labelWidth + cellWidth * Double(index) + cellWidth / 2
            body += """
            <text x="\(f(cx))" y="17" text-anchor="middle" fill="\(ink)" opacity="0.65" \
            font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="10">\(abbrev)</text>
            """
        }
        for (rowIndex, record) in package.records.enumerated() {
            let y = headerHeight + rowHeight * Double(rowIndex)
            if rowIndex.isMultiple(of: 2) {
                body += "<rect x=\"0\" y=\"\(f(y))\" width=\"\(f(width))\" height=\"\(f(rowHeight))\" fill=\"#f5efe5\" opacity=\"0.5\"/>"
            }
            body += """
            <text x="10" y="\(f(y + 15))" fill="\(ink)" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">\(Html.escape(record.capability.label))</text>
            """
            for (index, (platform, _)) in platformAbbrev.enumerated() {
                let cx = labelWidth + cellWidth * Double(index) + cellWidth / 2
                let (fill, mark): (String, String)
                switch record.platforms[platform.rawValue]?.status {
                case .supported: (fill, mark) = (good, "✓")
                case .conditional: (fill, mark) = (warn, "◐")
                case .unsupported: (fill, mark) = (quiet, "–")
                case .unknown, nil: (fill, mark) = (quiet, "?")
                }
                body += """
                <text x="\(f(cx))" y="\(f(y + 15.5))" text-anchor="middle" fill="\(fill)" \
                font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="12" font-weight="bold">\(mark)</text>
                """
            }
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(f(width))" height="\(f(height))" role="img" aria-label="\(Html.escape(package.name)) capability matrix — SwiftServe">
          <title>\(Html.escape(package.name)) — capability × platform matrix, verified by SwiftServe</title>
          <rect width="\(f(width))" height="\(f(height))" rx="6" fill="\(cream)" stroke="#efe7db"/>
          \(body)
        </svg>
        """
    }

    private static func f(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
