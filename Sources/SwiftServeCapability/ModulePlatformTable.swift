import Foundation

/// Which platforms each importable module exists on — how `canImport(...)`
/// conditions get decided. Loaded as DATA at runtime (bundled JSON, like the
/// denylist) so corrections are a PR, not a code change.
///
/// The contract: an entry is authoritative in BOTH directions — platform in
/// the set means importable, platform missing means not importable. A module
/// with no entry at all is honestly indeterminate. Curate accordingly: omit a
/// module entirely rather than ship a half-known entry.
public struct ModulePlatformTable: Codable, Sendable, Equatable {
    public let version: Int
    public let modules: [String: [String]]

    public init(version: Int, modules: [String: [String]]) {
        self.version = version
        self.modules = modules
    }

    public static func decode(from data: Data) throws -> ModulePlatformTable {
        try JSONDecoder().decode(ModulePlatformTable.self, from: data)
    }

    /// The platforms a module exists on; nil when the module is unknown.
    public func platforms(for module: String) -> Set<Platform>? {
        guard let names = modules[module] else { return nil }
        return Set(names.compactMap(Platform.init(rawValue:)))
    }

    /// An empty table — every canImport resolves indeterminate. Useful for
    /// tests and as a safe fallback.
    public static let empty = ModulePlatformTable(version: 0, modules: [:])
}
