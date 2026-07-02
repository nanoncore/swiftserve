import SwiftSyntax
import SwiftServeCapability

/// Turns a `#if` condition expression into a structured `PlatformCondition`.
/// The contract that keeps verdicts trustworthy: anything we can't understand
/// becomes `.unknown` carrying the exact source text — parse, never guess.
enum ConditionParser {

    static func parse(_ expr: ExprSyntax) -> PlatformCondition {
        // (…) — unwrap a single unlabeled parenthesized element.
        if let tuple = expr.as(TupleExprSyntax.self) {
            guard tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil else {
                return .unknown(expr.trimmedDescription)
            }
            return parse(only.expression)
        }

        // !condition
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            guard prefix.operator.text == "!" else { return .unknown(expr.trimmedDescription) }
            return .not(parse(prefix.expression))
        }

        // Folded binary form (some producers hand us this shape directly).
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            guard let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else {
                return .unknown(expr.trimmedDescription)
            }
            let lhs = parse(infix.leftOperand), rhs = parse(infix.rightOperand)
            switch op {
            case "&&": return .allOf(flatten(lhs, rhs, joining: { if case .allOf(let ops) = $0 { ops } else { nil } }))
            case "||": return .anyOf(flatten(lhs, rhs, joining: { if case .anyOf(let ops) = $0 { ops } else { nil } }))
            default: return .unknown(expr.trimmedDescription)
            }
        }

        // Unfolded sequence — what SwiftParser actually produces for a && b || c.
        if let sequence = expr.as(SequenceExprSyntax.self) {
            return foldSequence(sequence)
        }

        // os(iOS) / canImport(UIKit) / targetEnvironment(macCatalyst) / arch(arm64) / swift(>=5.9)
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return parseCall(call)
        }

        // Bare identifier: DEBUG-style compilation flag.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return .flag(ref.baseName.text)
        }

        // #if true / #if false — rare, honest as a flag the resolver won't decide.
        if let literal = expr.as(BooleanLiteralExprSyntax.self) {
            return .flag(literal.literal.text)
        }

        return .unknown(expr.trimmedDescription)
    }

    private static func parseCall(_ call: FunctionCallExprSyntax) -> PlatformCondition {
        guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              let argument = call.arguments.first, call.arguments.count == 1 else {
            return .unknown(call.trimmedDescription)
        }
        let argumentText = argument.expression.trimmedDescription
        switch callee {
        case "os":
            // The platform must be a bare identifier — anything fancier is unknown.
            guard argument.expression.is(DeclReferenceExprSyntax.self) else {
                return .unknown(call.trimmedDescription)
            }
            return .os(argumentText)
        case "canImport":
            // Accepts `UIKit` and submodule forms like `UIKit.UIGestureRecognizer`.
            return .canImport(argumentText)
        case "targetEnvironment":
            return .targetEnvironment(argumentText)
        case "arch":
            return .arch(argumentText)
        case "swift", "compiler":
            // The corpus is parsed as current-toolchain source; the resolver treats
            // these as true, and the raw text rides along for audit.
            return .languageVersion(call.trimmedDescription)
        default:
            return .unknown(call.trimmedDescription)
        }
    }

    /// Folds an unfolded operand/operator sequence with just enough precedence
    /// knowledge for `#if` conditions: `&&` binds tighter than `||`. Any other
    /// operator makes the whole expression `.unknown`.
    private static func foldSequence(_ node: SequenceExprSyntax) -> PlatformCondition {
        var operands: [PlatformCondition] = []
        var operators: [String] = []
        for (index, element) in node.elements.enumerated() {
            if index.isMultiple(of: 2) {
                operands.append(parse(element))
            } else if let op = element.as(BinaryOperatorExprSyntax.self) {
                operators.append(op.operator.text)
            } else {
                return .unknown(node.trimmedDescription)
            }
        }
        guard operands.count == operators.count + 1, !operators.isEmpty,
              operators.allSatisfy({ $0 == "&&" || $0 == "||" }) else {
            return .unknown(node.trimmedDescription)
        }

        // Split on || first; each group is an &&-conjunction.
        var orGroups: [[PlatformCondition]] = [[operands[0]]]
        for (op, rhs) in zip(operators, operands.dropFirst()) {
            if op == "||" {
                orGroups.append([rhs])
            } else {
                orGroups[orGroups.count - 1].append(rhs)
            }
        }
        let groups = orGroups.map { PlatformCondition.conjunction($0)! }
        return groups.count == 1 ? groups[0] : .anyOf(groups)
    }

    private static func flatten(_ lhs: PlatformCondition, _ rhs: PlatformCondition,
                                joining unwrap: (PlatformCondition) -> [PlatformCondition]?) -> [PlatformCondition] {
        (unwrap(lhs) ?? [lhs]) + (unwrap(rhs) ?? [rhs])
    }
}
