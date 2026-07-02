import Foundation

/// The platform axis capability verdicts run over.
public enum Platform: String, Codable, CaseIterable, Sendable {
    case iOS, macOS, watchOS, tvOS, visionOS, macCatalyst, linux
}

/// Evaluates a declaration's `#if` condition + `@available` constraints into
/// per-platform presence, using three-valued (Kleene) logic: provably true,
/// provably false, or indeterminate. Indeterminate never collapses into a
/// guess — it surfaces as `.conditional` carrying the condition text.
public enum PlatformResolver {

    public static func resolve(condition: PlatformCondition?,
                               availability: [AvailabilityConstraint],
                               modules: ModulePlatformTable) -> [String: PlatformPresence] {
        var result: [String: PlatformPresence] = [:]
        for platform in Platform.allCases {
            result[platform.rawValue] = presence(
                on: platform, condition: condition, availability: availability, modules: modules)
        }
        return result
    }

    private static func presence(on platform: Platform, condition: PlatformCondition?,
                                 availability: [AvailabilityConstraint],
                                 modules: ModulePlatformTable) -> PlatformPresence {
        // @available(P, unavailable) dominates: an explicit fence beats any #if.
        if isUnavailable(on: platform, availability: availability) { return .absent }

        guard let condition else { return .present }
        switch evaluate(condition, on: platform, modules: modules) {
        case .yes: return .present
        case .no: return .absent
        case .indeterminate: return .conditional(condition.rendered)
        }
    }

    // MARK: - @available overlay

    private static func isUnavailable(on platform: Platform,
                                      availability: [AvailabilityConstraint]) -> Bool {
        availability.contains { constraint in
            constraint.unavailable && appliesTo(platform, constraintPlatform: constraint.platform)
        }
    }

    /// Which platform names bind to which axis value. Catalyst compiles as
    /// iOS, so iOS constraints reach it unless a macCatalyst-specific
    /// constraint exists — mirroring the `os(iOS)` rule below.
    private static func appliesTo(_ platform: Platform, constraintPlatform: String) -> Bool {
        if constraintPlatform == "*" { return true }
        switch platform {
        case .macCatalyst:
            return constraintPlatform == "macCatalyst" || constraintPlatform == "iOS"
        case .linux:
            return false   // @available names Apple platforms only
        default:
            return constraintPlatform == platform.rawValue
        }
    }

    // MARK: - Three-valued condition evaluation

    enum Truth { case yes, no, indeterminate }

    static func evaluate(_ condition: PlatformCondition, on platform: Platform,
                         modules: ModulePlatformTable) -> Truth {
        switch condition {
        case .os(let name):
            return evaluateOS(name, on: platform)

        case .canImport(let module):
            // canImport(UIKit.UIGestureRecognizerSubclass) keys on the top module.
            let top = module.split(separator: ".").first.map(String.init) ?? module
            guard let known = modules.platforms(for: top) else { return .indeterminate }
            return known.contains(platform) ? .yes : .no

        case .targetEnvironment(let environment):
            switch environment {
            case "macCatalyst": return platform == .macCatalyst ? .yes : .no
            case "simulator": return .indeterminate   // orthogonal to the platform axis
            default: return .indeterminate
            }

        case .languageVersion:
            // The corpus is parsed as current-toolchain source; raw text is
            // preserved on the decl for audit.
            return .yes

        case .arch, .unknown:
            return .indeterminate

        case .flag(let name):
            // `#if true` / `#if false` literals are decidable; build flags aren't.
            switch name {
            case "true": return .yes
            case "false": return .no
            default: return .indeterminate
            }

        case .not(let operand):
            switch evaluate(operand, on: platform, modules: modules) {
            case .yes: return .no
            case .no: return .yes
            case .indeterminate: return .indeterminate
            }

        case .allOf(let operands):
            var sawIndeterminate = false
            for operand in operands {
                switch evaluate(operand, on: platform, modules: modules) {
                case .no: return .no                    // false && anything = false
                case .indeterminate: sawIndeterminate = true
                case .yes: continue
                }
            }
            return sawIndeterminate ? .indeterminate : .yes

        case .anyOf(let operands):
            var sawIndeterminate = false
            for operand in operands {
                switch evaluate(operand, on: platform, modules: modules) {
                case .yes: return .yes                  // true || anything = true
                case .indeterminate: sawIndeterminate = true
                case .no: continue
                }
            }
            return sawIndeterminate ? .indeterminate : .no
        }
    }

    private static func evaluateOS(_ name: String, on platform: Platform) -> Truth {
        // xrOS was visionOS's pre-release spelling; normalize it.
        let osName = name == "xrOS" ? "visionOS" : name
        switch platform {
        case .macCatalyst:
            // The crucial subtlety: Catalyst compiles as iOS — os(iOS) is TRUE
            // under Catalyst, os(macOS) is FALSE.
            return osName == "iOS" ? .yes : .no
        case .linux:
            return osName == "Linux" ? .yes : .no
        default:
            return osName == platform.rawValue ? .yes : .no
        }
    }
}
