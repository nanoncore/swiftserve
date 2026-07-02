import Foundation

/// How a dependency is sourced, mirroring SwiftPM's `kind` field in Package.resolved.
public enum PinKind: String, Codable, Sendable, Equatable {
    case remoteSourceControl
    case localSourceControl
    case registry
    case unknown
}

/// The *shape* of a pin's resolved state. A `version` pin tracks a released tag;
/// `branch` and `revision` pins do not — which is a supply-chain smell we capture.
public enum PinType: String, Codable, Sendable, Equatable {
    case version
    case branch
    case revision
    case unknown
}

/// A single resolved dependency, parsed from one entry of `Package.resolved`.
///
/// This is the clean, platform-agnostic model the scorer reads. It deliberately
/// carries only what the resolved file actually contains — no manifest data.
public struct Pin: Codable, Sendable, Equatable {
    public let identity: String
    public let kind: PinKind
    public let location: String
    /// Semver string when this is a `version` pin, else `nil`.
    public let resolvedVersion: String?
    /// Branch name when this is a `branch` pin, else `nil`.
    public let branch: String?
    /// Commit hash when present (branch and revision pins always carry one).
    public let revision: String?
    public let pinType: PinType

    public init(
        identity: String,
        kind: PinKind,
        location: String,
        resolvedVersion: String?,
        branch: String?,
        revision: String?,
        pinType: PinType
    ) {
        self.identity = identity
        self.kind = kind
        self.location = location
        self.resolvedVersion = resolvedVersion
        self.branch = branch
        self.revision = revision
        self.pinType = pinType
    }
}
