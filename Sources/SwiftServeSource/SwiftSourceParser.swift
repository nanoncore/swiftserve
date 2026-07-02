import Foundation
import SwiftSyntax
import SwiftParser
import SwiftServeScan

/// Parses Swift source into `CandidateSite`s — the dynamic-access patterns whose
/// string arguments might resolve to private API. This is the ONLY SwiftSyntax in the
/// codebase, and it makes *no* privacy judgment: it extracts, `SourceScanner` decides.
///
/// Pure: source string in, candidate sites out (testable with no disk). The AST is the
/// whole point — a `Selector("_x")` inside a comment or an unrelated string literal is
/// simply not a call node, so it never becomes a candidate. That's what grep can't do.
public enum SwiftSourceParser {

    public static func candidates(in source: String, file: String) -> [CandidateSite] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        let collector = Collector(file: file, converter: converter)
        collector.walk(tree)
        return collector.sites
    }

    /// Walks the tree collecting candidate sites. A class because `SyntaxVisitor` is one.
    private final class Collector: SyntaxVisitor {
        let file: String
        let converter: SourceLocationConverter
        var sites: [CandidateSite] = []

        init(file: String, converter: SourceLocationConverter) {
            self.file = file
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let (kind, api, argExpr) = classify(node), let form = argumentForm(argExpr) {
                sites.append(site(kind: kind, api: api, form: form, at: Syntax(node)))
            }
            return .visitChildren
        }

        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            // @_silgen_name("foo") / @_cdecl("foo") name a C symbol directly.
            guard let name = node.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                  name == "_silgen_name" || name == "_cdecl" else { return .visitChildren }
            if let strlit = firstStringLiteral(in: Syntax(node)), let form = argumentForm(ExprSyntax(strlit)) {
                sites.append(site(kind: .symbol, api: "@\(name)", form: form, at: Syntax(node)))
            }
            return .visitChildren
        }

        // MARK: - Classify a call into a candidate kind + the string argument

        private func classify(_ node: FunctionCallExprSyntax) -> (SourceCallKind, String, ExprSyntax)? {
            guard let callee = calleeName(node.calledExpression) else { return nil }
            switch callee {
            case "Selector", "NSSelectorFromString":
                if let arg = node.arguments.first?.expression { return (.selector, "\(callee)(_:)", arg) }
            case "NSClassFromString":
                if let arg = node.arguments.first?.expression { return (.classLookup, "NSClassFromString(_:)", arg) }
            case "dlopen":
                if let arg = node.arguments.first?.expression { return (.dynamicLoadPath, "dlopen", arg) }
            case "dlsym":
                // dlsym(handle, "symbol") — the symbol name is the second argument.
                let args = Array(node.arguments)
                if args.count >= 2 { return (.symbol, "dlsym", args[1].expression) }
            case "value", "mutableArrayValue", "mutableSetValue", "mutableOrderedSetValue":
                if let arg = labeledArg(node, labels: ["forKey", "forKeyPath"]) { return (.kvcKey, "\(callee)(forKey:)", arg) }
            case "setValue":
                if let arg = labeledArg(node, labels: ["forKey", "forKeyPath"]) { return (.kvcKey, "setValue(_:forKey:)", arg) }
            default:
                break
            }
            return nil
        }

        private func calleeName(_ expr: ExprSyntax) -> String? {
            if let decl = expr.as(DeclReferenceExprSyntax.self) { return decl.baseName.text }
            if let member = expr.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
            return nil
        }

        private func labeledArg(_ node: FunctionCallExprSyntax, labels: [String]) -> ExprSyntax? {
            for arg in node.arguments where arg.label.map({ labels.contains($0.text) }) ?? false {
                return arg.expression
            }
            return nil
        }

        // MARK: - Read the string argument's form (literal vs constructed)

        private func argumentForm(_ expr: ExprSyntax) -> ArgumentForm? {
            if let strlit = expr.as(StringLiteralExprSyntax.self) {
                let hasInterpolation = strlit.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
                let parts = strlit.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
                if !hasInterpolation { return .literal(parts.joined()) }   // one readable literal
                let segs = parts.filter { !$0.isEmpty }
                return segs.isEmpty ? nil : .constructed(segs)             // interpolation
            }
            // Concatenation or any other expression: salvage whatever literal fragments
            // we can read; a value with no readable fragment is fully dynamic → not a site.
            let segs = literalSegments(in: Syntax(expr)).filter { !$0.isEmpty }
            return segs.isEmpty ? nil : .constructed(segs)
        }

        private func literalSegments(in node: Syntax) -> [String] {
            var out: [String] = []
            for child in node.children(viewMode: .sourceAccurate) {
                if let strlit = child.as(StringLiteralExprSyntax.self) {
                    out += strlit.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
                } else {
                    out += literalSegments(in: child)
                }
            }
            return out
        }

        private func firstStringLiteral(in node: Syntax) -> StringLiteralExprSyntax? {
            for child in node.children(viewMode: .sourceAccurate) {
                if let s = child.as(StringLiteralExprSyntax.self) { return s }
                if let nested = firstStringLiteral(in: child) { return nested }
            }
            return nil
        }

        private func site(kind: SourceCallKind, api: String, form: ArgumentForm, at node: Syntax) -> CandidateSite {
            let loc = node.startLocation(converter: converter)
            return CandidateSite(kind: kind, api: api, argument: form,
                                 location: SourceLocation(file: file, line: loc.line, column: loc.column),
                                 analyzer: .swiftSyntax)
        }
    }
}
