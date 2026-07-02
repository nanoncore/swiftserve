import Foundation
import SwiftServeCore

/// The canonical output of a build-cost run — same contract as the other Scoops: JSON is the
/// source of truth, the terminal card renders from it. The vocabulary is *cost*, presented as
/// share-of-build, never wall-clock seconds (frontend jobs run in parallel).
public struct BuildCostReport: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let target: Target
    public let swiftee: Verdict
    public let summary: Summary
    public let entries: [BuildCostEntry]   // ranked, full set (the card caps; JSON carries all)
    public let warnings: [String]

    public static let currentVersion = 1

    public init(generatedAt: String, target: Target, swiftee: Verdict, summary: Summary,
                entries: [BuildCostEntry], warnings: [String]) {
        self.reportVersion = BuildCostReport.currentVersion
        self.generatedAt = generatedAt; self.target = target; self.swiftee = swiftee
        self.summary = summary; self.entries = entries; self.warnings = warnings
    }

    public struct Target: Codable, Sendable, Equatable {
        public let path: String
        public let mode: String            // "build" | "log"
        public let buildSucceeded: Bool
        public let compiledModules: Int?   // nil in log mode; 0 ⇒ cached build
        public init(path: String, mode: String, buildSucceeded: Bool, compiledModules: Int?) {
            self.path = path; self.mode = mode
            self.buildSucceeded = buildSucceeded; self.compiledModules = compiledModules
        }
        enum CodingKeys: String, CodingKey { case path, mode, buildSucceeded, compiledModules }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(mode, forKey: .mode)
            try c.encode(buildSucceeded, forKey: .buildSucceeded)
            try c.encode(compiledModules, forKey: .compiledModules)   // explicit null in log mode
        }
    }

    /// Swiftee's reaction — same brand vocabulary as every surface, in the encouraging
    /// "here's what's worth knowing" register, never a scolding.
    public struct Verdict: Codable, Sendable, Equatable {
        public let mood: Mood
        public let voiceLine: String
        public let headline: String
        public init(mood: Mood, voiceLine: String, headline: String) {
            self.mood = mood; self.voiceLine = voiceLine; self.headline = headline
        }
    }

    /// The numbers behind the headline. Everything is share-of-build-aware; `*WallMs` are
    /// compile-work totals, useful for ratios, not for "seconds you waited".
    public struct Summary: Codable, Sendable, Equatable {
        public let totalFrontendWallMs: Int
        public let yourCodeWallMs: Int
        public let dependencyWallMs: Int
        public let unattributedWallMs: Int
        public let yourCodeSharePercent: Double
        public let dependencySharePercent: Double
        public let entryCount: Int
        public let targetCount: Int
        public let dependencyCount: Int
        public let moduleCount: Int
        public let healthCrossed: Bool     // did we have offline health to cross dependencies with?
        public let buildSucceeded: Bool
        public let cachedBuild: Bool        // nothing recompiled ⇒ little to measure

        public init(totalFrontendWallMs: Int, yourCodeWallMs: Int, dependencyWallMs: Int,
                    unattributedWallMs: Int, yourCodeSharePercent: Double, dependencySharePercent: Double,
                    entryCount: Int, targetCount: Int, dependencyCount: Int, moduleCount: Int,
                    healthCrossed: Bool, buildSucceeded: Bool, cachedBuild: Bool) {
            self.totalFrontendWallMs = totalFrontendWallMs; self.yourCodeWallMs = yourCodeWallMs
            self.dependencyWallMs = dependencyWallMs; self.unattributedWallMs = unattributedWallMs
            self.yourCodeSharePercent = yourCodeSharePercent; self.dependencySharePercent = dependencySharePercent
            self.entryCount = entryCount; self.targetCount = targetCount
            self.dependencyCount = dependencyCount; self.moduleCount = moduleCount
            self.healthCrossed = healthCrossed; self.buildSucceeded = buildSucceeded; self.cachedBuild = cachedBuild
        }
    }
}
