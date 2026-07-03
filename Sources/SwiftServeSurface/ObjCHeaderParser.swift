import Foundation
import SwiftServeCapability

/// Objective-C *header* extraction — the UIKit-era half of the surface.
///
/// Headers ARE the public ObjC surface, so a hand-written scanner over `.h`
/// files closes most of the "N ObjC files unparsed" blind spot without
/// dragging libclang into the dependency graph (SwiftServeSurface stays
/// thin; the verdict machinery stays in SwiftServeCapability). What this
/// deliberately does NOT do:
///
///   · implementation files (`.m`) — private by construction, still counted
///     as unparsed so labeling stays honest
///   · C function prototypes — rare as capability anchors; a future pass
///   · macro *expansion* — package-defined macros (`SD_UIKIT`) survive as
///     opaque flags, which the resolver reports as `conditional`, exactly
///     like `SQLITE_HAS_CODEC` on the Swift side
///
/// Everything it emits is a plain `SurfaceDecl`: the same resolver pass
/// computes per-platform presence from `TARGET_OS_*` conditions and
/// `API_AVAILABLE`-family constraints, so ObjC decls get the identical
/// three-valued treatment Swift decls do.
public enum ObjCHeaderParser {

    // MARK: - entry

    public static func decls(in source: String, file: String) -> [SurfaceDecl] {
        var out: [SurfaceDecl] = []
        var pp = PreprocessorStack()
        var container: Container?
        var pendingDoc: String?
        // Availability macros conventionally sit on their own line ABOVE the
        // @interface they decorate — carried forward to the next container.
        var pendingAvailability: [AvailabilityConstraint] = []
        var enumContext: EnumContext?
        var inBlockComment = false

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            var line = lines[index]
            index += 1

            // Block comments can open and close anywhere; docs are whatever
            // comment content sat immediately above a declaration.
            (line, inBlockComment, pendingDoc) = stripComments(
                line, inBlockComment: inBlockComment, pendingDoc: pendingDoc)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // --- preprocessor ---
            if trimmed.hasPrefix("#") {
                pp.consume(trimmed)
                continue
            }

            // --- enum body ---
            if var context = enumContext {
                if let caseName = context.caseName(from: trimmed) {
                    out.append(decl(name: "\(context.name).\(caseName)", kind: .enumCase,
                                    signature: nil, file: file, line: lineNumber,
                                    pp: pp, container: nil, doc: nil))
                }
                if trimmed.contains("}") { enumContext = nil } else { enumContext = context }
                pendingDoc = nil
                continue
            }

            // A line that is ONLY availability macros decorates the next
            // container ("API_AVAILABLE(ios(14.0))" above "@interface …").
            let standalone = availability(in: trimmed)
            if !standalone.isEmpty,
               stripAvailabilityMacros(trimmed).trimmingCharacters(in: .whitespaces).isEmpty {
                pendingAvailability += standalone
                continue
            }

            // --- containers ---
            if trimmed.hasPrefix("@interface") || trimmed.hasPrefix("@protocol") {
                // Forward declaration (`@protocol SDWebImageOperation;`) — not a decl.
                if trimmed.hasPrefix("@protocol") && trimmed.hasSuffix(";") { pendingDoc = nil; continue }
                let carried = pendingAvailability
                pendingAvailability = []
                guard let parsed = Container.parse(trimmed, availability: carried + availability(in: trimmed)) else {
                    pendingDoc = nil
                    continue
                }
                container = parsed
                if !parsed.isCategory {
                    out.append(decl(name: parsed.name,
                                    kind: trimmed.hasPrefix("@protocol") ? .protocol : .class,
                                    signature: collapse(trimmed), file: file, line: lineNumber,
                                    pp: pp, container: nil, doc: pendingDoc,
                                    availability: parsed.availability))
                }
                pendingDoc = nil
                continue
            }
            if trimmed.hasPrefix("@end") {
                container = nil
                pendingDoc = nil
                continue
            }
            if trimmed.hasPrefix("@class") { pendingDoc = nil; continue }

            // --- members ---
            if let current = container {
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("+") {
                    let (text, consumed) = accumulate(lines: lines, from: index - 1, until: ";")
                    index = consumed
                    if let selector = selector(from: text) {
                        out.append(decl(name: "\(current.name).\(selector)", kind: .function,
                                        signature: collapse(text), file: file, line: lineNumber,
                                        pp: pp, container: current, doc: pendingDoc,
                                        availability: availability(in: text)))
                    }
                    pendingDoc = nil
                    continue
                }
                if trimmed.hasPrefix("@property") {
                    let (text, consumed) = accumulate(lines: lines, from: index - 1, until: ";")
                    index = consumed
                    if let name = propertyName(from: text) {
                        out.append(decl(name: "\(current.name).\(name)", kind: .property,
                                        signature: collapse(text), file: file, line: lineNumber,
                                        pp: pp, container: current, doc: pendingDoc,
                                        availability: availability(in: text)))
                    }
                    pendingDoc = nil
                    continue
                }
                continue
            }

            // --- top level ---
            if let opened = EnumContext.parse(trimmed) {
                out.append(decl(name: opened.name, kind: .enum, signature: collapse(trimmed),
                                file: file, line: lineNumber, pp: pp, container: nil,
                                doc: pendingDoc, availability: availability(in: trimmed)))
                if !trimmed.contains("}") { enumContext = opened }
                pendingDoc = nil
                continue
            }
            if let name = externConstant(from: trimmed) {
                out.append(decl(name: name, kind: .property, signature: collapse(trimmed),
                                file: file, line: lineNumber, pp: pp, container: nil,
                                doc: pendingDoc, availability: availability(in: trimmed)))
                pendingDoc = nil
                continue
            }
            if let name = staticConstant(from: trimmed) {
                out.append(decl(name: name, kind: .enumCase, signature: collapse(trimmed),
                                file: file, line: lineNumber, pp: pp, container: nil,
                                doc: pendingDoc, availability: availability(in: trimmed)))
                pendingDoc = nil
                continue
            }
            if !trimmed.hasPrefix("//") { pendingDoc = nil }
        }
        return out
    }

    // MARK: - decl assembly

    private static func decl(name: String, kind: DeclKind, signature: String?,
                             file: String, line: Int, pp: PreprocessorStack,
                             container: Container?, doc: String?,
                             availability: [AvailabilityConstraint] = []) -> SurfaceDecl {
        // Members inherit their container's constraints, merged with their
        // own — mirroring the Swift extractor's enclosing-type merge.
        var merged = availability
        if let container { merged = container.availability + merged }
        let condition = pp.condition
        return SurfaceDecl(
            name: name, kind: kind, signature: signature,
            location: SurfaceLocation(file: file, line: line),
            condition: condition, rawCondition: condition?.rendered,
            availability: merged, resolvedPlatforms: nil,
            docSummary: doc, hasMacroAttributes: false)
    }

    // MARK: - containers

    private struct Container {
        let name: String
        let isCategory: Bool
        let availability: [AvailabilityConstraint]

        static func parse(_ line: String, availability: [AvailabilityConstraint]) -> Container? {
            // "@interface Name : Super <P>" | "@interface Name (Category)" | "@protocol Name <P>"
            let afterKeyword = line.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
            guard let name = afterKeyword.prefixMatch(of: /[A-Za-z_][A-Za-z0-9_]*/).map({ String($0.0) })
            else { return nil }
            let rest = afterKeyword.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            return Container(name: name, isCategory: rest.hasPrefix("("), availability: availability)
        }
    }

    private struct EnumContext {
        let name: String

        static func parse(_ line: String) -> EnumContext? {
            guard let match = line.firstMatch(of: /typedef\s+NS_(?:ENUM|OPTIONS)\s*\(\s*[^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/)
            else { return nil }
            return EnumContext(name: String(match.1))
        }

        func caseName(from line: String) -> String? {
            guard let match = line.prefixMatch(of: /([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|,|$)/) else { return nil }
            let candidate = String(match.1)
            return candidate == "}" ? nil : candidate
        }
    }

    // MARK: - members

    /// Selector from a method declaration: strip availability macros and
    /// parenthesized type annotations, then join the `part:` segments.
    static func selector(from text: String) -> String? {
        var stripped = stripAvailabilityMacros(text)
        if let semicolon = stripped.firstIndex(of: ";") { stripped = String(stripped[..<semicolon]) }
        stripped = removingParenthesized(stripped)
        let parts = stripped.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\s*:/).map { String($0.1) }
        if !parts.isEmpty { return parts.map { $0 + ":" }.joined() }
        // No arguments: "- (void)cancel;" → the last bare identifier.
        return stripped.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).last.map { String($0.0) }
    }

    /// The declared name of an `@property`: the identifier after `^` for
    /// block properties, else the last identifier before the semicolon.
    static func propertyName(from text: String) -> String? {
        var stripped = stripAvailabilityMacros(text)
        if let semicolon = stripped.firstIndex(of: ";") { stripped = String(stripped[..<semicolon]) }
        if let block = stripped.firstMatch(of: /\^\s*([A-Za-z_][A-Za-z0-9_]*)/) { return String(block.1) }
        // Drop the attribute list so "(nonatomic, copy)" identifiers never win.
        if let close = stripped.firstIndex(of: ")"), stripped.contains("(") {
            stripped = String(stripped[stripped.index(after: close)...])
        }
        return stripped.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).last.map { String($0.0) }
    }

    static func externConstant(from line: String) -> String? {
        guard line.firstMatch(of: /^(?:FOUNDATION_EXPORT|FOUNDATION_EXTERN|UIKIT_EXTERN|APPKIT_EXTERN|extern)\b/) != nil,
              line.contains(";"), !line.contains("(")
        else { return nil }
        let stripped = stripAvailabilityMacros(String(line.prefix(while: { $0 != ";" })))
        return stripped.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).last.map { String($0.0) }
    }

    /// The `NS_TYPED_EXTENSIBLE_ENUM` idiom: `static const SDImageFormat
    /// SDImageFormatWebP = 4;` — header-level constants that are, in
    /// practice, the enum cases capability claims anchor to.
    static func staticConstant(from line: String) -> String? {
        line.firstMatch(of: /^static\s+const\s+[A-Za-z_][A-Za-z0-9_]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/)
            .map { String($0.1) }
    }

    // MARK: - availability macros

    private static let platformTokens: [String: String] = [
        "ios": "iOS", "macos": "macOS", "macosx": "macOS", "osx": "macOS",
        "tvos": "tvOS", "watchos": "watchOS", "visionos": "visionOS", "xros": "visionOS",
        "maccatalyst": "macCatalyst", "macCatalyst": "macCatalyst",
    ]

    /// Every availability constraint the macros on this declaration text
    /// impose. Legacy `NS_*` forms are folded into the same model.
    static func availability(in text: String) -> [AvailabilityConstraint] {
        var constraints: [AvailabilityConstraint] = []

        for match in text.matches(of: /API_AVAILABLE\(([^()]*(?:\([^()]*\)[^()]*)*)\)/) {
            constraints += apiParts(String(match.1)).map {
                AvailabilityConstraint(platform: $0.platform, introduced: $0.versions.first)
            }
        }
        for match in text.matches(of: /API_UNAVAILABLE\(([^)]*)\)/) {
            for token in String(match.1).split(separator: ",") {
                let key = token.trimmingCharacters(in: .whitespaces)
                if let platform = platformTokens[key.lowercased()] {
                    constraints.append(AvailabilityConstraint(platform: platform, unavailable: true))
                }
            }
        }
        for match in text.matches(of: /API_DEPRECATED(?:_WITH_REPLACEMENT)?\(\s*"[^"]*"\s*,\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/) {
            constraints += apiParts(String(match.1)).map {
                AvailabilityConstraint(platform: $0.platform, introduced: $0.versions.first,
                                       deprecated: $0.versions.count > 1 ? $0.versions[1] : "unversioned")
            }
        }
        // Legacy NS_ macros: versions written 10_10 / 8_0.
        if let match = text.firstMatch(of: /NS_(?:CLASS_)?AVAILABLE\(\s*([0-9_A-Za-z]+)\s*,\s*([0-9_A-Za-z]+)\s*\)/) {
            if let mac = legacyVersion(String(match.1)) {
                constraints.append(AvailabilityConstraint(platform: "macOS", introduced: mac))
            }
            if let ios = legacyVersion(String(match.2)) {
                constraints.append(AvailabilityConstraint(platform: "iOS", introduced: ios))
            }
        }
        if let match = text.firstMatch(of: /NS_(?:CLASS_)?AVAILABLE_IOS\(\s*([0-9_]+)\s*\)/) {
            constraints.append(AvailabilityConstraint(platform: "iOS", introduced: legacyVersion(String(match.1))))
        }
        if let match = text.firstMatch(of: /NS_(?:CLASS_)?AVAILABLE_MAC\(\s*([0-9_]+)\s*\)/) {
            constraints.append(AvailabilityConstraint(platform: "macOS", introduced: legacyVersion(String(match.1))))
        }
        if let match = text.firstMatch(of: /NS_DEPRECATED_IOS\(\s*([0-9_]+)\s*,\s*([0-9_]+)/) {
            constraints.append(AvailabilityConstraint(platform: "iOS", introduced: legacyVersion(String(match.1)),
                                                      deprecated: legacyVersion(String(match.2))))
        }
        if text.contains("NS_UNAVAILABLE") {
            constraints.append(AvailabilityConstraint(platform: "*", unavailable: true))
        }
        return constraints
    }

    private static func apiParts(_ list: String) -> [(platform: String, versions: [String])] {
        list.matches(of: /([A-Za-z]+)\s*\(\s*([^)]*)\s*\)/).compactMap { match in
            guard let platform = platformTokens[String(match.1).lowercased()] else { return nil }
            let versions = String(match.2).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return (platform, versions)
        }
    }

    private static func legacyVersion(_ raw: String) -> String? {
        // 10_10 → "10.10"; NA / NSFoundationVersionNumber gunk → nil.
        guard raw.first?.isNumber == true else { return nil }
        return raw.replacingOccurrences(of: "_", with: ".")
    }

    static func stripAvailabilityMacros(_ text: String) -> String {
        text.replacing(/(?:API_AVAILABLE|API_UNAVAILABLE|API_DEPRECATED(?:_WITH_REPLACEMENT)?|NS_(?:CLASS_)?AVAILABLE(?:_IOS|_MAC)?|NS_DEPRECATED_IOS|NS_SWIFT_NAME|NS_SWIFT_UI_ACTOR)\([^()]*(?:\([^()]*\)[^()]*)*\)/, with: " ")
            .replacingOccurrences(of: "NS_UNAVAILABLE", with: " ")
            .replacingOccurrences(of: "NS_DESIGNATED_INITIALIZER", with: " ")
            .replacingOccurrences(of: "NS_REQUIRES_NIL_TERMINATION", with: " ")
    }

    // MARK: - preprocessor conditions

    /// `#if` nesting with `#elif`/`#else` negation, mirroring the manual
    /// `IfConfigDecl` walk on the Swift side. Each frame remembers the
    /// branches already taken so later branches conjoin their negations.
    struct PreprocessorStack {
        private struct Frame {
            var taken: [PlatformCondition]
            var current: PlatformCondition?
        }
        private var frames: [Frame] = []

        var condition: PlatformCondition? {
            let live = frames.compactMap(\.current)
            switch live.count {
            case 0: return nil
            case 1: return live[0]
            default: return .allOf(live)
            }
        }

        mutating func consume(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^#\s*if\s+(.+)$/) {
                let condition = ObjCHeaderParser.parseCondition(String(match.1))
                frames.append(Frame(taken: [condition], current: condition))
            } else if let match = trimmed.firstMatch(of: /^#\s*ifdef\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                let condition = ObjCHeaderParser.mapToken(String(match.1))
                frames.append(Frame(taken: [condition], current: condition))
            } else if let match = trimmed.firstMatch(of: /^#\s*ifndef\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                let condition = PlatformCondition.not(ObjCHeaderParser.mapToken(String(match.1)))
                frames.append(Frame(taken: [condition], current: condition))
            } else if let match = trimmed.firstMatch(of: /^#\s*elif\s+(.+)$/) {
                guard !frames.isEmpty else { return }
                let branch = ObjCHeaderParser.parseCondition(String(match.1))
                var frame = frames.removeLast()
                let negations = frame.taken.map { PlatformCondition.not($0) }
                frame.current = .allOf(negations + [branch]).simplified
                frame.taken.append(branch)
                frames.append(frame)
            } else if trimmed.firstMatch(of: /^#\s*else\b/) != nil {
                guard !frames.isEmpty else { return }
                var frame = frames.removeLast()
                let negations = frame.taken.map { PlatformCondition.not($0) }
                frame.current = negations.count == 1 ? negations[0] : .allOf(negations)
                frames.append(frame)
            } else if trimmed.firstMatch(of: /^#\s*endif\b/) != nil {
                if !frames.isEmpty { frames.removeLast() }
            }
            // #define / #import / #pragma / #include — no condition impact.
        }
    }

    /// A `#if` expression → `PlatformCondition`. Supports `!`, `&&`, `||`,
    /// parentheses, `defined(X)`, `__has_include(<M/h.h>)`, and the
    /// `TARGET_OS_*` family; anything else survives as an opaque flag.
    static func parseCondition(_ expression: String) -> PlatformCondition {
        var parser = ConditionExpressionParser(expression)
        return parser.parseOr() ?? .unknown(expression.trimmingCharacters(in: .whitespaces))
    }

    static func mapToken(_ token: String) -> PlatformCondition {
        switch token {
        case "TARGET_OS_IOS": .os("iOS")
        case "TARGET_OS_OSX": .os("macOS")
        case "TARGET_OS_TV": .os("tvOS")
        case "TARGET_OS_WATCH": .os("watchOS")
        case "TARGET_OS_VISION", "TARGET_OS_XR": .os("visionOS")
        case "TARGET_OS_MACCATALYST", "TARGET_OS_UIKITFORMAC": .targetEnvironment("macCatalyst")
        case "TARGET_OS_SIMULATOR": .targetEnvironment("simulator")
        case "TARGET_OS_IPHONE", "TARGET_OS_EMBEDDED":
            .anyOf([.os("iOS"), .os("tvOS"), .os("watchOS"), .os("visionOS"),
                    .targetEnvironment("macCatalyst")])
        // TARGET_OS_MAC is 1 on EVERY Apple platform — mapping it to
        // os(macOS) would fabricate absences. Opaque flag = honest
        // "conditional" from the resolver.
        default: .flag(token)
        }
    }

    private struct ConditionExpressionParser {
        private var tokens: [String]
        private var index = 0

        init(_ expression: String) {
            tokens = expression.matches(of: /__has_include\s*\(\s*[<"][^>"]*[>"]\s*\)|defined\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\)|[A-Za-z_][A-Za-z0-9_]*|&&|\|\||!|\(|\)|[0-9]+/)
                .map { String($0.0) }
        }

        private var peek: String? { index < tokens.count ? tokens[index] : nil }
        private mutating func advance() -> String? {
            defer { index += 1 }
            return peek
        }

        mutating func parseOr() -> PlatformCondition? {
            guard var left = parseAnd() else { return nil }
            while peek == "||" {
                _ = advance()
                guard let right = parseAnd() else { return left }
                left = .anyOf(flatten(left, right) { if case .anyOf(let ops) = $0 { ops } else { nil } })
            }
            return left
        }

        private mutating func parseAnd() -> PlatformCondition? {
            guard var left = parseUnary() else { return nil }
            while peek == "&&" {
                _ = advance()
                guard let right = parseUnary() else { return left }
                left = .allOf(flatten(left, right) { if case .allOf(let ops) = $0 { ops } else { nil } })
            }
            return left
        }

        private mutating func parseUnary() -> PlatformCondition? {
            guard let token = advance() else { return nil }
            switch token {
            case "!":
                return parseUnary().map { .not($0) }
            case "(":
                let inner = parseOr()
                if peek == ")" { _ = advance() }
                return inner
            default:
                if let match = token.firstMatch(of: /defined\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/) {
                    return ObjCHeaderParser.mapToken(String(match.1))
                }
                if let match = token.firstMatch(of: /__has_include\s*\(\s*[<"]([A-Za-z_][A-Za-z0-9_]*)/) {
                    return .canImport(String(match.1))
                }
                if token.first?.isNumber == true { return .flag(token) }
                return ObjCHeaderParser.mapToken(token)
            }
        }

        private func flatten(_ left: PlatformCondition, _ right: PlatformCondition,
                             _ operands: (PlatformCondition) -> [PlatformCondition]?) -> [PlatformCondition] {
            (operands(left) ?? [left]) + (operands(right) ?? [right])
        }
    }

    // MARK: - text helpers

    /// Comment stripping that keeps the last comment's content as a doc
    /// candidate for the next declaration.
    private static func stripComments(_ line: String, inBlockComment: Bool,
                                      pendingDoc: String?) -> (String, Bool, String?) {
        var text = line
        var inBlock = inBlockComment
        var doc = pendingDoc

        if inBlock {
            if let close = text.range(of: "*/") {
                text = String(text[close.upperBound...])
                inBlock = false
            } else {
                let content = docContent(text)
                if !content.isEmpty { doc = (doc.map { $0 + " " } ?? "") + content }
                return ("", true, doc)
            }
        }
        while let open = text.range(of: "/*") {
            if let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) {
                let content = docContent(String(text[open.upperBound..<close.lowerBound]))
                if !content.isEmpty { doc = content }
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                let content = docContent(String(text[open.upperBound...]))
                doc = content.isEmpty ? doc : content
                text = String(text[..<open.lowerBound])
                inBlock = true
                break
            }
        }
        if let slashes = text.range(of: "///") ?? text.range(of: "//") {
            let content = docContent(String(text[slashes.upperBound...]))
            if !content.isEmpty { doc = content }
            text = String(text[..<slashes.lowerBound])
        }
        return (text, inBlock, doc.map { String($0.prefix(140)) })
    }

    private static func docContent(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "*!/ \t"))
    }

    private static func removingParenthesized(_ text: String) -> String {
        var depth = 0
        var out = ""
        for character in text {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(character) }
        }
        return out
    }

    private static func collapse(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(220))
    }

    /// Join continuation lines until the terminator appears; returns the
    /// combined text and the index of the line after the last consumed one.
    private static func accumulate(lines: [String], from start: Int,
                                   until terminator: Character) -> (String, Int) {
        var text = lines[start]
        var next = start + 1
        while !text.contains(terminator) && next < lines.count && next - start < 8 {
            text += " " + lines[next]
            next += 1
        }
        return (text, next)
    }
}

private extension PlatformCondition {
    /// `allOf([x])` → `x`, purely cosmetic for rendered conditions.
    var simplified: PlatformCondition {
        if case .allOf(let ops) = self, ops.count == 1 { return ops[0] }
        return self
    }
}
