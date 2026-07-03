import Foundation

// The compile-the-truth evidence channel: a package either builds for a
// platform at its pinned commit or it doesn't. Verdicts are curated artifacts
// (in-repo JSON under `data/build-verdicts/`, one file per package ×
// platform) produced by `swiftserve index build-probe`; the validator
// cross-checks any record anchor that cites one, exactly as it grounds
// symbol anchors in surfaces.

/// One probe's outcome: the package at `commit`, compiled for `platform`
/// against a real SDK. `built` proves the whole surface compiles there;
/// `failed` carries the compiler's own words as the receipt; `inconclusive`
/// means the PROBE broke (no scheme, destination missing, setup error) —
/// it grounds nothing, ever.
public struct BuildVerdict: Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case built, failed, inconclusive }

    public static let currentVersion = 1

    public let verdictVersion: Int
    public let canonicalURL: String
    public let commit: String
    public let platform: String        // Platform.rawValue
    public let outcome: Outcome
    public let toolchain: String       // e.g. "Xcode 26.6 (17F70)"
    public let sdk: String             // e.g. "XROS26.5.sdk"
    public let destination: String     // the xcodebuild destination probed
    public let scheme: String          // the scheme actually built
    public let errorExcerpt: [String]  // compiler error lines when failed; [] when built
    public let probedAt: String        // ISO8601 — verdicts are curated artifacts

    public init(verdictVersion: Int = BuildVerdict.currentVersion, canonicalURL: String,
                commit: String, platform: String, outcome: Outcome, toolchain: String,
                sdk: String, destination: String, scheme: String,
                errorExcerpt: [String] = [], probedAt: String) {
        self.verdictVersion = verdictVersion
        self.canonicalURL = canonicalURL
        self.commit = commit
        self.platform = platform
        self.outcome = outcome
        self.toolchain = toolchain
        self.sdk = sdk
        self.destination = destination
        self.scheme = scheme
        self.errorExcerpt = errorExcerpt
        self.probedAt = probedAt
    }

    /// How verdicts are keyed when handed to the validator.
    public static func key(canonicalURL: String, platform: String) -> String {
        "\(canonicalURL)#\(platform)"
    }

    public var key: String { Self.key(canonicalURL: canonicalURL, platform: platform) }

    public static func decode(from data: Data) throws -> BuildVerdict {
        try JSONDecoder().decode(BuildVerdict.self, from: data)
    }
}

extension BuildVerdict: Codable {}
