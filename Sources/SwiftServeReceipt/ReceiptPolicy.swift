import Foundation
import SwiftServeCapability

public enum ReceiptPolicyError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedVersion(Int)
    case duplicateKey(String)
    case unknownKey(String)
    case unknownRule(String)
    case invalidSeverity(String)
    case invalidRequirement(String)
    case unknownPlatform(String)

    public var description: String {
        switch self {
        case .malformed(let detail): "malformed policy: \(detail)"
        case .unsupportedVersion(let version): "unsupported policy version \(version); expected version 1"
        case .duplicateKey(let key): "policy contains duplicate key ‘\(key)’"
        case .unknownKey(let key): "policy contains unknown key ‘\(key)’"
        case .unknownRule(let rule): "policy contains unknown rule ‘\(rule)’"
        case .invalidSeverity(let severity): "policy severity ‘\(severity)’ is invalid; use info, review, or block"
        case .invalidRequirement(let detail): "malformed capability requirement: \(detail)"
        case .unknownPlatform(let platform): "unknown platform ‘\(platform)’ in capability requirement"
        }
    }
}

public struct CapabilityRequirement: Codable, Sendable, Equatable {
    public let package: String
    public let capability: String
    public let platform: String
    public let expect: ClaimStatus

    public init(package: String, capability: String, platform: String, expect: ClaimStatus) {
        self.package = package
        self.capability = capability
        self.platform = platform
        self.expect = expect
    }
}

public struct ReceiptPolicy: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    /// User overrides. Keys may be stable finding codes or documented aliases.
    public let rules: [String: ReceiptSeverity]
    public let requiredCapabilities: [CapabilityRequirement]

    public init(version: Int = ReceiptPolicy.currentVersion,
                rules: [String: ReceiptSeverity] = [:],
                requiredCapabilities: [CapabilityRequirement] = []) {
        self.version = version
        self.rules = rules
        self.requiredCapabilities = requiredCapabilities
    }

    public static let `default` = ReceiptPolicy()

    public static func decode(from data: Data) throws -> ReceiptPolicy {
        if let duplicate = try DuplicateJSONKeyDetector.firstDuplicate(in: data) {
            throw ReceiptPolicyError.duplicateKey(duplicate)
        }
        let raw: RawPolicy
        do {
            raw = try JSONDecoder().decode(RawPolicy.self, from: data)
        } catch let error as DecodingError {
            throw ReceiptPolicyError.malformed(Self.describe(error))
        } catch {
            throw ReceiptPolicyError.malformed(error.localizedDescription)
        }
        guard raw.version == currentVersion else {
            throw ReceiptPolicyError.unsupportedVersion(raw.version)
        }
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for key in top?.keys ?? Dictionary<String, Any>().keys where !["version", "rules", "requiredCapabilities"].contains(key) {
            throw ReceiptPolicyError.unknownKey(key)
        }
        if let rawRequirements = top?["requiredCapabilities"] as? [Any] {
            let allowed = Set(["package", "capability", "platform", "expect"])
            for (index, value) in rawRequirements.enumerated() {
                guard let object = value as? [String: Any] else {
                    throw ReceiptPolicyError.invalidRequirement("entry \(index) is not an object")
                }
                if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
                    throw ReceiptPolicyError.invalidRequirement("entry \(index) contains unknown key ‘\(unknown)’")
                }
            }
        }

        var rules: [String: ReceiptSeverity] = [:]
        for (key, value) in raw.rules ?? [:] {
            guard knownRuleNames.contains(key) else { throw ReceiptPolicyError.unknownRule(key) }
            guard let severity = ReceiptSeverity(rawValue: value) else {
                throw ReceiptPolicyError.invalidSeverity(value)
            }
            rules[key] = severity
        }
        let requirements = try (raw.requiredCapabilities ?? []).map { requirement in
            guard !requirement.package.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReceiptPolicyError.invalidRequirement("package is empty")
            }
            guard !requirement.capability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReceiptPolicyError.invalidRequirement("capability is empty")
            }
            guard let platform = Platform.allCases.first(where: {
                $0.rawValue.lowercased() == requirement.platform.lowercased()
            }) else {
                throw ReceiptPolicyError.unknownPlatform(requirement.platform)
            }
            return CapabilityRequirement(package: requirement.package, capability: requirement.capability,
                                         platform: platform.rawValue, expect: requirement.expect)
        }
        return ReceiptPolicy(version: raw.version, rules: rules, requiredCapabilities: requirements)
    }

    public func severity(for code: FindingCode) -> ReceiptSeverity {
        if let exact = rules[code.rawValue] { return exact }
        for alias in Self.aliases(for: code) {
            if let severity = rules[alias] { return severity }
        }
        return Self.defaultSeverity[code] ?? .info
    }

    public static let defaultSeverity: [FindingCode: ReceiptSeverity] = [
        .packageAdded: .info,
        .packageRemoved: .review,
        .majorUpdate: .review,
        .minorUpdate: .info,
        .patchUpdate: .info,
        .downgrade: .review,
        .stableToPrerelease: .review,
        .prereleaseToStable: .info,
        .prereleaseChange: .review,
        .branchPin: .block,
        .revisionPin: .block,
        .pinTypeChange: .review,
        .revisionChange: .review,
        .sourceChange: .block,
        .duplicateIdentity: .block,
        .conflictingIdentity: .block,
        .unknownVersion: .review,
        .capabilityStillTrue: .info,
        .capabilityTruthChanged: .block,
        .capabilityAnchorGone: .review,
        .capabilityNeedsProbe: .review,
        .capabilityUnavailable: .review,
        .capabilityUnverified: .review,
        .capabilityNotIndexed: .info,
        .capabilityFirstPartySkipped: .info,
        .requiredCapabilityMismatch: .block,
        .requiredCapabilityUnverified: .review,
    ]

    private static let ruleAliases = [
        "removed-package", "major-update", "downgrade", "prerelease",
        "branch-pin", "revision-pin", "source-change", "capability-unverified",
    ]

    private static let knownRuleNames = Set(FindingCode.allCases.map(\.rawValue) + ruleAliases)

    private static func aliases(for code: FindingCode) -> [String] {
        switch code {
        case .packageRemoved: ["removed-package"]
        case .majorUpdate: ["major-update"]
        case .downgrade: ["downgrade"]
        case .stableToPrerelease, .prereleaseChange: ["prerelease"]
        case .branchPin: ["branch-pin"]
        case .revisionPin: ["revision-pin"]
        case .sourceChange: ["source-change"]
        case .capabilityUnavailable, .capabilityUnverified, .requiredCapabilityUnverified: ["capability-unverified"]
        default: []
        }
    }

    private struct RawPolicy: Decodable {
        let version: Int
        let rules: [String: String]?
        let requiredCapabilities: [CapabilityRequirement]?
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): context.debugDescription
        @unknown default: "invalid JSON"
        }
    }
}

/// Foundation's decoders accept duplicate object keys. Policy is fail-closed,
/// so this small JSON scanner rejects them before Codable decoding.
private enum DuplicateJSONKeyDetector {
    static func firstDuplicate(in data: Data) throws -> String? {
        var parser = Parser(bytes: Array(data))
        try parser.value()
        parser.space()
        guard parser.index == parser.bytes.count else { throw ReceiptPolicyError.malformed("trailing data") }
        return parser.duplicate
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var duplicate: String?

        mutating func space() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws {
            space()
            guard index < bytes.count else { throw ReceiptPolicyError.malformed("unexpected end of input") }
            switch bytes[index] {
            case 123: try object()
            case 91: try array()
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default: try number()
            }
        }

        mutating func object() throws {
            index += 1
            space()
            var keys = Set<String>()
            if consume(125) { return }
            while true {
                let key = try string()
                if !keys.insert(key).inserted, duplicate == nil { duplicate = key }
                space()
                guard consume(58) else { throw ReceiptPolicyError.malformed("expected ':'") }
                try value()
                space()
                if consume(125) { return }
                guard consume(44) else { throw ReceiptPolicyError.malformed("expected ','") }
                space()
            }
        }

        mutating func array() throws {
            index += 1
            space()
            if consume(93) { return }
            while true {
                try value()
                space()
                if consume(93) { return }
                guard consume(44) else { throw ReceiptPolicyError.malformed("expected ','") }
            }
        }

        mutating func string() throws -> String {
            space()
            let start = index
            guard consume(34) else { throw ReceiptPolicyError.malformed("expected string") }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    do {
                        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    } catch {
                        throw ReceiptPolicyError.malformed("invalid string escape")
                    }
                }
                if byte == 92 {
                    guard index < bytes.count else { break }
                    index += 1
                }
            }
            throw ReceiptPolicyError.malformed("unterminated string")
        }

        mutating func number() throws {
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ReceiptPolicyError.malformed("invalid value") }
        }

        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw ReceiptPolicyError.malformed("invalid literal")
            }
            index += expected.count
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
