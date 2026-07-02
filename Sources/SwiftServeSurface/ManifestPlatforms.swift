import SwiftSyntax
import SwiftParser
import SwiftServeCapability

/// Reads the `platforms:` declaration out of a Package.swift — syntactically,
/// without executing the manifest. Remember what this means: SPM `platforms:`
/// only RAISES minimum deployment versions for the platforms it lists. It
/// never excludes a platform. These are version floors, recorded as evidence;
/// the validator forbids using them to ground an `unsupported` verdict.
public enum ManifestPlatforms {

    /// The manifest's `platforms:` entries; `[]` when the manifest has no
    /// `platforms:` argument (every platform at default floors); `nil` when
    /// no `Package(...)` call could be found at all (programmatic manifest —
    /// flagged upstream as `manifestUnparsed`).
    public static func extract(from source: String) -> [ManifestPlatform]? {
        let tree = Parser.parse(source: source)
        let finder = PackageCallFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        guard let packageCall = finder.packageCall else { return nil }

        guard let platformsArg = packageCall.arguments.first(where: { $0.label?.text == "platforms" }) else {
            return []
        }
        guard let array = platformsArg.expression.as(ArrayExprSyntax.self) else {
            // platforms: someVariable — built programmatically, can't read it.
            return nil
        }
        // Elements we can't read are skipped, not guessed; `.custom` and the
        // `.iOS(.v13)` / `.macOS("10.15")` forms are all handled.
        return array.elements.compactMap { parseElement($0.expression) }
    }

    private static func parseElement(_ expr: ExprSyntax) -> ManifestPlatform? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let name = member.declName.baseName.text

        if name == "custom" {
            // .custom("openbsd", versionString: "7.0")
            let platform = call.arguments.first.flatMap { stringLiteral($0.expression) }
            let version = call.arguments.first(where: { $0.label?.text == "versionString" })
                .flatMap { stringLiteral($0.expression) }
            guard let platform else { return nil }
            return ManifestPlatform(platform: platform, minVersion: version)
        }

        return ManifestPlatform(platform: name, minVersion: call.arguments.first.flatMap { version($0.expression) })
    }

    private static func version(_ expr: ExprSyntax) -> String? {
        // .v10_15 → "10.15" ; .v13 → "13"
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let raw = member.declName.baseName.text
            guard raw.hasPrefix("v") else { return raw }
            return raw.dropFirst().replacingOccurrences(of: "_", with: ".")
        }
        // .macOS("10.15")
        return stringLiteral(expr)
    }

    private static func stringLiteral(_ expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
        return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    }

    /// Whether the manifest declares any `.binaryTarget(...)` — a blind spot
    /// for source extraction (the real capability fence may live inside the
    /// shipped binary, as LiveKit's Krisp filter proves). Surfaced in stats so
    /// labeling confidence gets capped, never inflated.
    public static func hasBinaryTargets(in source: String) -> Bool {
        let tree = Parser.parse(source: source)
        let finder = BinaryTargetFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.found
    }

    private final class PackageCallFinder: SyntaxVisitor {
        var packageCall: FunctionCallExprSyntax?

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if packageCall == nil,
               node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Package" {
                packageCall = node
                return .skipChildren
            }
            return .visitChildren
        }
    }

    private final class BinaryTargetFinder: SyntaxVisitor {
        var found = false

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "binaryTarget" {
                found = true
                return .skipChildren
            }
            return found ? .skipChildren : .visitChildren
        }
    }
}
