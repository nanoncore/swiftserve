import Foundation
import SwiftServeCore

/// The canonical output of a build-time-pointer run — same contract as the other Scoops:
/// JSON is the source of truth, the terminal card renders from it. The vocabulary is
/// deliberately *pointers*, not findings — these are suggestions, not violations.
public struct BuildTimingReport: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let target: Target
    public let swiftee: Verdict
    public let summary: Summary
    public let pointers: [Pointer]   // ranked, full set (the card caps; JSON carries all)
    public let warnings: [String]
    public let config: ConfigInfo

    public static let currentVersion = 1

    public init(generatedAt: String, target: Target, swiftee: Verdict, summary: Summary,
                pointers: [Pointer], warnings: [String], config: ConfigInfo) {
        self.reportVersion = BuildTimingReport.currentVersion
        self.generatedAt = generatedAt; self.target = target; self.swiftee = swiftee
        self.summary = summary; self.pointers = pointers; self.warnings = warnings; self.config = config
    }

    public struct Target: Codable, Sendable, Equatable {
        public let path: String
        public let mode: String            // "build" | "log"
        public let buildSucceeded: Bool
        public let compiledUnits: Int?     // nil in log mode
        public init(path: String, mode: String, buildSucceeded: Bool, compiledUnits: Int?) {
            self.path = path; self.mode = mode
            self.buildSucceeded = buildSucceeded; self.compiledUnits = compiledUnits
        }
        enum CodingKeys: String, CodingKey { case path, mode, buildSucceeded, compiledUnits }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(mode, forKey: .mode)
            try c.encode(buildSucceeded, forKey: .buildSucceeded)
            try c.encode(compiledUnits, forKey: .compiledUnits)   // explicit null in log mode
        }
    }

    /// Swiftee's reaction — same brand vocabulary as every other surface, but the voice is
    /// the encouraging "here's a quick win" register, never "you did this wrong".
    public struct Verdict: Codable, Sendable, Equatable {
        public let mood: Mood
        public let voiceLine: String
        public let headline: String
        public init(mood: Mood, voiceLine: String, headline: String) {
            self.mood = mood; self.voiceLine = voiceLine; self.headline = headline
        }
    }

    /// The numbers behind the headline. `topNRecoverableMs` is the sum of the detailed
    /// top-N — the "fix these and recover ~X" figure that makes the ranking actionable.
    public struct Summary: Codable, Sendable, Equatable {
        public let flaggedSiteCount: Int
        public let slowExpressionCount: Int
        public let slowFunctionBodyCount: Int
        public let detailedCount: Int          // how many the card details (min(topN, flagged))
        public let rolledUpCount: Int          // the "+ M more" remainder
        public let topNRecoverableMs: Int      // sum of the detailed sites
        public let totalFlaggedMs: Int         // sum of every flagged site
        public let totalTypeCheckMs: Int?      // from -stats-output-dir, when available
        public let dependencySitesIgnored: Int // over-threshold sites dropped as non-first-party
        public let buildSucceeded: Bool
        public let cachedBuild: Bool

        public init(flaggedSiteCount: Int, slowExpressionCount: Int, slowFunctionBodyCount: Int,
                    detailedCount: Int, rolledUpCount: Int, topNRecoverableMs: Int, totalFlaggedMs: Int,
                    totalTypeCheckMs: Int?, dependencySitesIgnored: Int, buildSucceeded: Bool, cachedBuild: Bool) {
            self.flaggedSiteCount = flaggedSiteCount
            self.slowExpressionCount = slowExpressionCount
            self.slowFunctionBodyCount = slowFunctionBodyCount
            self.detailedCount = detailedCount; self.rolledUpCount = rolledUpCount
            self.topNRecoverableMs = topNRecoverableMs; self.totalFlaggedMs = totalFlaggedMs
            self.totalTypeCheckMs = totalTypeCheckMs
            self.dependencySitesIgnored = dependencySitesIgnored
            self.buildSucceeded = buildSucceeded; self.cachedBuild = cachedBuild
        }

        enum CodingKeys: String, CodingKey {
            case flaggedSiteCount, slowExpressionCount, slowFunctionBodyCount, detailedCount
            case rolledUpCount, topNRecoverableMs, totalFlaggedMs, totalTypeCheckMs
            case dependencySitesIgnored, buildSucceeded, cachedBuild
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(flaggedSiteCount, forKey: .flaggedSiteCount)
            try c.encode(slowExpressionCount, forKey: .slowExpressionCount)
            try c.encode(slowFunctionBodyCount, forKey: .slowFunctionBodyCount)
            try c.encode(detailedCount, forKey: .detailedCount)
            try c.encode(rolledUpCount, forKey: .rolledUpCount)
            try c.encode(topNRecoverableMs, forKey: .topNRecoverableMs)
            try c.encode(totalFlaggedMs, forKey: .totalFlaggedMs)
            try c.encode(totalTypeCheckMs, forKey: .totalTypeCheckMs)   // explicit null when absent
            try c.encode(dependencySitesIgnored, forKey: .dependencySitesIgnored)
            try c.encode(buildSucceeded, forKey: .buildSucceeded)
            try c.encode(cachedBuild, forKey: .cachedBuild)
        }
    }

    /// Echoes the thresholds the run used — so the JSON is self-describing about the bar
    /// it held sites to.
    public struct ConfigInfo: Codable, Sendable, Equatable {
        public let version: Int
        public let expressionThresholdMs: Int
        public let functionBodyThresholdMs: Int
        public let topN: Int
        public init(config: TimingConfig) {
            self.version = config.version
            self.expressionThresholdMs = config.expressionThresholdMs
            self.functionBodyThresholdMs = config.functionBodyThresholdMs
            self.topN = config.topN
        }
    }
}
