import SwiftSyntax
import SwiftServeCapability

/// Reads `@available(...)` attributes into `AvailabilityConstraint`s. Handles
/// both the shorthand form (`@available(iOS 14.0, macOS 11.0, *)`) and the
/// long form (`@available(macOS, unavailable)` / `introduced:` / `deprecated:`
/// / `obsoleted:` / `message:`). Defensive throughout: an argument shape we
/// don't recognize is skipped, never misread.
enum AvailabilityParser {

    /// All constraints declared by every `@available` attribute in a list.
    static func constraints(in attributes: AttributeListSyntax) -> [AvailabilityConstraint] {
        attributes.compactMap { $0.as(AttributeSyntax.self) }
            .filter { attributeName($0) == "available" }
            .flatMap { constraints(in: $0) }
    }

    private static func constraints(in attribute: AttributeSyntax) -> [AvailabilityConstraint] {
        guard let arguments = attribute.arguments?.as(AvailabilityArgumentListSyntax.self) else { return [] }

        var shorthand: [AvailabilityConstraint] = []   // platform+version pairs
        var platform: String?                          // long form names one platform
        var unavailable = false
        var introduced: String?, deprecated: String?, obsoleted: String?, message: String?
        var sawLongFormMarker = false

        for argument in arguments {
            switch argument.argument {
            case .availabilityVersionRestriction(let restriction):
                if let version = restriction.version {
                    shorthand.append(AvailabilityConstraint(
                        platform: restriction.platform.text, introduced: version.trimmedDescription))
                } else if platform == nil {
                    platform = restriction.platform.text
                }
            case .token(let token):
                switch token.text {
                case "*":
                    break
                case "unavailable":
                    unavailable = true; sawLongFormMarker = true
                case "deprecated":
                    deprecated = deprecated ?? "unversioned"; sawLongFormMarker = true
                case "noasync":
                    sawLongFormMarker = true
                default:
                    if platform == nil { platform = token.text }
                }
            case .availabilityLabeledArgument(let labeled):
                sawLongFormMarker = true
                let value: String
                switch labeled.value {
                case .version(let version): value = version.trimmedDescription
                case .string(let string): value = string.segments.trimmedDescription
                }
                switch labeled.label.text {
                case "introduced": introduced = value
                case "deprecated": deprecated = value
                case "obsoleted": obsoleted = value
                case "message": message = value
                default: break   // renamed: and future labels — metadata we don't model
                }
            }
        }

        var result = shorthand
        if let platform, sawLongFormMarker || shorthand.isEmpty {
            result.append(AvailabilityConstraint(
                platform: platform, introduced: introduced, deprecated: deprecated,
                obsoleted: obsoleted, unavailable: unavailable, message: message))
        } else if platform == nil, sawLongFormMarker {
            // `@available(*, deprecated)` — applies everywhere.
            result.append(AvailabilityConstraint(
                platform: "*", introduced: introduced, deprecated: deprecated,
                obsoleted: obsoleted, unavailable: unavailable, message: message))
        }
        return result
    }

    static func attributeName(_ attribute: AttributeSyntax) -> String? {
        attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
    }
}
