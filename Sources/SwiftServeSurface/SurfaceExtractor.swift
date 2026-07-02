import Foundation
import SwiftSyntax
import SwiftParser
import SwiftServeCapability

/// Extracts a source file's *public API surface* — every public/open
/// declaration, qualified by its enclosing types, together with the `#if`
/// platform conditions and `@available` constraints that fence it. This is
/// the deterministic half of capability search: it reports what the source
/// says, and only what the source says.
///
/// Pure: source string in, `[SurfaceDecl]` out — the same seam as
/// `SwiftSourceParser` in the private-API pillar. The CLI walks files.
public enum SurfaceExtractor {

    public static func decls(in source: String, file: String) -> [SurfaceDecl] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        let collector = SurfaceCollector(file: file, converter: converter)
        collector.walk(tree)
        return collector.decls
    }

    // MARK: - Access levels

    enum AccessLevel: Int, Comparable {
        case privateAccess = 0, filePrivateAccess, internalAccess, packageAccess, publicAccess, openAccess

        static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool { lhs.rawValue < rhs.rawValue }

        init?(modifierName: String) {
            switch modifierName {
            case "open": self = .openAccess
            case "public": self = .publicAccess
            case "package": self = .packageAccess
            case "internal": self = .internalAccess
            case "fileprivate": self = .filePrivateAccess
            case "private": self = .privateAccess
            default: return nil
            }
        }
    }

    // MARK: - The visitor

    private final class SurfaceCollector: SyntaxVisitor {
        let file: String
        let converter: SourceLocationConverter
        var decls: [SurfaceDecl] = []

        /// One enclosing `#if` level = one effective condition (already the
        /// conjunction of that level's clause + negated prior clauses).
        private var conditionStack: [PlatformCondition] = []

        private struct ContextFrame {
            enum Kind { case type, enumType, protocolType, extensionType }
            let name: String
            let kind: Kind
            /// Ceiling for members' effective access — the enclosing type's own
            /// effective access. Extensions keep the parent floor: the extended
            /// type may live in another file, and v1 is decl-level truth.
            let floor: AccessLevel
            /// What a member without an explicit modifier gets.
            let memberDefault: AccessLevel
            /// Availability accumulated from enclosing types.
            let availability: [AvailabilityConstraint]
        }

        private var contextStack: [ContextFrame] = []

        init(file: String, converter: SourceLocationConverter) {
            self.file = file
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        // MARK: #if — walked manually so #elseif/#else carry negated priors

        override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            var negatedPriors: [PlatformCondition] = []
            for clause in node.clauses {
                let own = clause.condition.map { ConditionParser.parse($0) }
                var parts = negatedPriors
                if let own { parts.append(own) }
                let effective = PlatformCondition.conjunction(parts)
                if let elements = clause.elements {
                    if let effective { conditionStack.append(effective) }
                    walk(elements)
                    if effective != nil { conditionStack.removeLast() }
                }
                if let own { negatedPriors.append(.not(own)) }
            }
            return .skipChildren
        }

        // MARK: Type-like declarations — emit, then descend with a new frame

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            enterType(name: node.name.text, kind: .class, frameKind: .type,
                      modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
        }
        override func visitPost(_ node: ClassDeclSyntax) { contextStack.removeLast() }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            enterType(name: node.name.text, kind: .struct, frameKind: .type,
                      modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
        }
        override func visitPost(_ node: StructDeclSyntax) { contextStack.removeLast() }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            enterType(name: node.name.text, kind: .enum, frameKind: .enumType,
                      modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
        }
        override func visitPost(_ node: EnumDeclSyntax) { contextStack.removeLast() }

        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            enterType(name: node.name.text, kind: .actor, frameKind: .type,
                      modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
        }
        override func visitPost(_ node: ActorDeclSyntax) { contextStack.removeLast() }

        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            enterType(name: node.name.text, kind: .protocol, frameKind: .protocolType,
                      modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
        }
        override func visitPost(_ node: ProtocolDeclSyntax) { contextStack.removeLast() }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            // The extension itself isn't surface; it shapes its members' names,
            // default access, and inherited availability.
            let declared = declaredAccess(node.modifiers)
            contextStack.append(ContextFrame(
                name: node.extendedType.trimmedDescription,
                kind: .extensionType,
                floor: currentFloor,   // extended type's real access is unknowable cross-file (v1)
                memberDefault: declared ?? .internalAccess,
                availability: currentAvailability + AvailabilityParser.constraints(in: node.attributes)))
            return .visitChildren
        }
        override func visitPost(_ node: ExtensionDeclSyntax) { contextStack.removeLast() }

        // MARK: Member declarations — emit, don't descend into bodies

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            emit(name: node.name.text, kind: .function,
                 signature: "func \(node.name.text)\(node.signature.trimmedDescription)",
                 modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            return .skipChildren
        }

        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            emit(name: "init", kind: .initializer,
                 signature: "init\(node.optionalMark?.text ?? "")\(node.signature.trimmedDescription)",
                 modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            return .skipChildren
        }

        override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
            emit(name: "subscript", kind: .subscript,
                 signature: "subscript\(node.parameterClause.trimmedDescription) \(node.returnClause.trimmedDescription)",
                 modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            return .skipChildren
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let type = binding.typeAnnotation?.trimmedDescription ?? ""
                emit(name: pattern.identifier.text, kind: .property,
                     signature: "\(node.bindingSpecifier.text) \(pattern.identifier.text)\(type)",
                     modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            }
            return .skipChildren
        }

        override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
            // Enum cases take no access modifier — they are exactly as public as
            // their enum, which is this frame's floor.
            let isInsideEnum = contextStack.last?.kind == .enumType
            for element in node.elements {
                emit(name: element.name.text, kind: .enumCase,
                     signature: "case \(element.trimmedDescription)",
                     declaredOverride: isInsideEnum ? currentFloor : nil,
                     modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            }
            return .skipChildren
        }

        override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
            emit(name: node.name.text, kind: .typealias,
                 signature: node.trimmedDescription,
                 modifiers: node.modifiers, attributes: node.attributes, node: Syntax(node))
            return .skipChildren
        }

        // MARK: Shared emit + frame plumbing

        private var currentFloor: AccessLevel { contextStack.last?.floor ?? .openAccess }
        private var currentMemberDefault: AccessLevel { contextStack.last?.memberDefault ?? .internalAccess }
        private var currentAvailability: [AvailabilityConstraint] { contextStack.last?.availability ?? [] }

        /// Emits a type decl if public, then pushes its frame for members.
        private func enterType(name: String, kind: DeclKind, frameKind: ContextFrame.Kind,
                               modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax,
                               node: Syntax) -> SyntaxVisitorContinueKind {
            let effective = min(declaredAccess(modifiers) ?? currentMemberDefault, currentFloor)
            let availability = currentAvailability + AvailabilityParser.constraints(in: attributes)
            if effective >= .publicAccess {
                append(name: qualified(name), kind: kind, signature: nil,
                       availability: availability, attributes: attributes, node: node)
            }
            contextStack.append(ContextFrame(
                name: name,
                kind: frameKind,
                floor: effective,
                memberDefault: frameKind == .protocolType ? effective : .internalAccess,
                availability: availability))
            return .visitChildren
        }

        private func emit(name: String, kind: DeclKind, signature: String?,
                          declaredOverride: AccessLevel? = nil,
                          modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax,
                          node: Syntax) {
            let declared = declaredOverride ?? declaredAccess(modifiers) ?? currentMemberDefault
            guard min(declared, currentFloor) >= .publicAccess else { return }
            append(name: qualified(name), kind: kind, signature: signature,
                   availability: currentAvailability + AvailabilityParser.constraints(in: attributes),
                   attributes: attributes, node: node)
        }

        private func append(name: String, kind: DeclKind, signature: String?,
                            availability: [AvailabilityConstraint], attributes: AttributeListSyntax,
                            node: Syntax) {
            let condition = PlatformCondition.conjunction(conditionStack)
            decls.append(SurfaceDecl(
                name: name,
                kind: kind,
                signature: signature,
                location: SurfaceLocation(file: file, line: node.startLocation(converter: converter).line),
                condition: condition,
                rawCondition: condition?.rendered,
                availability: availability,
                resolvedPlatforms: nil,   // the resolver pass fills this
                docSummary: docSummary(from: node.leadingTrivia),
                hasMacroAttributes: hasMacroAttributes(attributes)))
        }

        private func qualified(_ name: String) -> String {
            (contextStack.map(\.name) + [name]).joined(separator: ".")
        }

        /// The decl's own access modifier, ignoring setter-only modifiers like
        /// `private(set)` — surface visibility is the *getter's* access.
        private func declaredAccess(_ modifiers: DeclModifierListSyntax) -> AccessLevel? {
            for modifier in modifiers where modifier.detail == nil {
                if let level = AccessLevel(modifierName: modifier.name.text) { return level }
            }
            return nil
        }

        // MARK: Doc comments + macro heuristic

        private func docSummary(from trivia: Trivia) -> String? {
            for piece in trivia {
                switch piece {
                case .docLineComment(let text):
                    let stripped = text.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespaces)
                    if !stripped.isEmpty { return stripped }
                case .docBlockComment(let text):
                    var body = text
                    if body.hasPrefix("/**") { body = String(body.dropFirst(3)) }
                    if body.hasSuffix("*/") { body = String(body.dropLast(2)) }
                    for line in body.split(separator: "\n") {
                        let stripped = line.trimmingCharacters(in: .whitespaces)
                            .drop(while: { $0 == "*" }).trimmingCharacters(in: .whitespaces)
                        if !stripped.isEmpty { return stripped }
                    }
                default:
                    continue
                }
            }
            return nil
        }

        /// Uppercase attributes that are known NOT to be attached macros —
        /// global actors, IB/KVO markers, and the common property wrappers.
        /// Anything else uppercase is treated as possibly-a-macro, which only
        /// ever *lowers* labeling confidence (over-flagging is the safe error).
        private static let knownUppercaseNonMacro: Set<String> = [
            "MainActor", "Sendable", "IBOutlet", "IBAction", "IBDesignable", "IBInspectable",
            "IBSegueAction", "NSCopying", "NSManaged", "GKInspectable",
            "NSApplicationMain", "UIApplicationMain",
            "State", "Published", "Binding", "ObservedObject", "StateObject",
            "EnvironmentObject", "Environment", "AppStorage", "SceneStorage",
            "FocusState", "Namespace", "ScaledMetric",
        ]

        private func hasMacroAttributes(_ attributes: AttributeListSyntax) -> Bool {
            for attribute in attributes.compactMap({ $0.as(AttributeSyntax.self) }) {
                guard let name = AvailabilityParser.attributeName(attribute),
                      let first = name.first, first.isUppercase,
                      !Self.knownUppercaseNonMacro.contains(name) else { continue }
                return true
            }
            return false
        }
    }
}
