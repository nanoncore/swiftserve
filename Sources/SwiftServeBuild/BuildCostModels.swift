import Foundation
import SwiftServeCore

/// Where a compiled module's cost lands. `yourTarget` is the code you can actually refactor;
/// `dependency` is a resolved SwiftPM package (the thing you can choose to keep or drop);
/// `unattributed` is a module we measured but couldn't tie back to either.
public enum CostOrigin: String, Codable, Sendable, Equatable {
    case yourTarget
    case dependency
    case unattributed
}

/// One per-module timing measurement, already aggregated from a `-stats-output-dir` run by the
/// CLI (summing the per-file frontend stats for that module across arches). The CLI produces
/// these impurely off disk; ``BuildCostAnalyzer`` consumes them purely. `packageIdentity` is the
/// owning package when the llbuild module→package map resolved it — nil for a first-party target
/// or an unattributed module.
///
/// `frontendWallMs` is the headline cost: total frontend wall (sema + SILGen + IRGen + SIL-opt),
/// summed across the module's files. It is compile *work*, NOT wall-clock — frontend jobs run in
/// parallel, so we only ever present it as a share of the whole build, never as seconds waited.
public struct ModuleTiming: Sendable, Equatable {
    public let module: String
    public let packageIdentity: String?
    public let origin: CostOrigin
    public let frontendWallMs: Int
    public let typeCheckWallMs: Int

    public init(module: String, packageIdentity: String?, origin: CostOrigin,
                frontendWallMs: Int, typeCheckWallMs: Int) {
        self.module = module; self.packageIdentity = packageIdentity; self.origin = origin
        self.frontendWallMs = frontendWallMs; self.typeCheckWallMs = typeCheckWallMs
    }
}

/// The minimal slice of Core's `PackageReport` the cost analyzer needs to make a dependency row
/// *actionable*: its offline (file-only) score and the flags behind it. The CLI maps
/// `PackageReport → DependencyHealth`, so the pure analyzer never imports the scoring stack.
/// This is the seam where the Core dep-health brain crosses the Build-timing pillar.
public struct DependencyHealth: Sendable, Equatable {
    public let identity: String
    public let score: Int          // 0–100, file-only
    public let flags: [String]
    public let version: String?

    public init(identity: String, score: Int, flags: [String], version: String?) {
        self.identity = identity; self.score = score; self.flags = flags; self.version = version
    }

    /// The Swiftee mood this score maps to — shared with every other surface.
    public var mood: Mood { Mood.from(score: score) }
}

/// Why a cost row is worth your eye. `slowestTarget` is the single biggest first-party win;
/// `expensiveAndUnhealthy` is a dependency that's both a real chunk of the build AND scoring
/// poorly — the only combination where "reconsider this dependency" is honest advice.
public enum CostHighlight: String, Codable, Sendable, Equatable {
    case slowestTarget
    case expensiveAndUnhealthy
    case none
}

/// One ranked row of the build-cost report — a target or a package, what it cost to compile, its
/// share of the build, and (for dependencies) its offline health. JSON is the source of truth;
/// optional fields encode as explicit `null`, same discipline as `Pointer`/`Finding`.
public struct BuildCostEntry: Codable, Sendable, Equatable {
    public let name: String              // module/target name, or package identity
    public let origin: CostOrigin
    public let frontendWallMs: Int       // compile work (see ModuleTiming) — never shown as seconds
    public let typeCheckWallMs: Int      // the type-check subset, as a secondary breakdown
    public let sharePercent: Double      // % of the build's total frontend wall, rounded to 0.1
    public let moduleCount: Int          // how many modules rolled into this row (a package can vendor many)
    public let packageVersion: String?   // resolved version for a dependency; nil otherwise
    public let healthScore: Int?         // offline health for a dependency; nil for your targets
    public let healthFlags: [String]     // empty unless a flagged dependency
    public let highlight: CostHighlight
    public let note: String              // the actionable one-liner (empty when highlight == .none)

    public init(name: String, origin: CostOrigin, frontendWallMs: Int, typeCheckWallMs: Int,
                sharePercent: Double, moduleCount: Int, packageVersion: String?,
                healthScore: Int?, healthFlags: [String], highlight: CostHighlight, note: String) {
        self.name = name; self.origin = origin
        self.frontendWallMs = frontendWallMs; self.typeCheckWallMs = typeCheckWallMs
        self.sharePercent = sharePercent; self.moduleCount = moduleCount
        self.packageVersion = packageVersion; self.healthScore = healthScore
        self.healthFlags = healthFlags; self.highlight = highlight; self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case name, origin, frontendWallMs, typeCheckWallMs, sharePercent, moduleCount
        case packageVersion, healthScore, healthFlags, highlight, note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(origin, forKey: .origin)
        try c.encode(frontendWallMs, forKey: .frontendWallMs)
        try c.encode(typeCheckWallMs, forKey: .typeCheckWallMs)
        try c.encode(sharePercent, forKey: .sharePercent)
        try c.encode(moduleCount, forKey: .moduleCount)
        try c.encode(packageVersion, forKey: .packageVersion)   // explicit null when absent
        try c.encode(healthScore, forKey: .healthScore)         // explicit null when absent
        try c.encode(healthFlags, forKey: .healthFlags)
        try c.encode(highlight, forKey: .highlight)
        try c.encode(note, forKey: .note)
    }
}
