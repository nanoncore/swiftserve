import Foundation
import SwiftServeCore

/// The canonical output of a source scan — same contract as the other Scoops: JSON is
/// the source of truth, the terminal summary renders from it. Findings are grouped by
/// confidence (definite first, possible below); the JSON carries everything the
/// terminal shows, plus exact `location`s.
public struct SourceScanReport: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let target: Target
    public let swiftee: BinaryReport.Verdict
    public let summary: Summary
    public let findings: [Finding]
    public let warnings: [String]
    public let denylist: BinaryReport.DenylistInfo

    public static let currentVersion = 1

    public init(generatedAt: String, target: Target, swiftee: BinaryReport.Verdict, summary: Summary,
                findings: [Finding], warnings: [String], denylist: BinaryReport.DenylistInfo) {
        self.reportVersion = SourceScanReport.currentVersion
        self.generatedAt = generatedAt; self.target = target; self.swiftee = swiftee
        self.summary = summary; self.findings = findings; self.warnings = warnings; self.denylist = denylist
    }

    public struct Target: Codable, Sendable, Equatable {
        public let path: String
        public let filesScanned: Int
        public let swiftFiles: Int
        public let objcFiles: Int
        public init(path: String, filesScanned: Int, swiftFiles: Int, objcFiles: Int) {
            self.path = path; self.filesScanned = filesScanned
            self.swiftFiles = swiftFiles; self.objcFiles = objcFiles
        }
    }

    /// Source findings are counted by confidence, not severity — that's the axis the
    /// user reads here ("definite vs. possible").
    public struct Summary: Codable, Sendable, Equatable {
        public let findingCount: Int
        public let definite: Int      // confidence == .high
        public let needsReview: Int   // confidence == .needsReview
        public init(findings: [Finding]) {
            findingCount = findings.count
            definite = findings.filter { $0.confidence == .high }.count
            needsReview = findings.filter { $0.confidence == .needsReview }.count
        }
    }
}

extension BinaryVerdict {
    /// Verdict for a source scan. Definite findings are serious; a pile of *possibles*
    /// alone is a gentle heads-up, never a scolding — crying wolf is what destroys trust
    /// on the most false-positive-prone surface.
    public static func makeSource(findings: [Finding]) -> BinaryReport.Verdict {
        if findings.isEmpty {
            return .init(mood: .partyMode,
                         voiceLine: "Nothing in your source reaching for private API — clean.",
                         headline: "No dynamic private-API access patterns found.")
        }
        let definite = findings.filter { $0.confidence == .high }.count
        let possible = findings.filter { $0.confidence == .needsReview }.count
        if definite > 0 {
            let tail = possible > 0 ? ", \(possible) to review" : ""
            return .init(mood: .meltdown,
                         voiceLine: "Dynamic calls that resolve to private API — App Review will flag these.",
                         headline: "\(definite) definite\(tail).")
        }
        return .init(mood: .softSqueeze,
                     voiceLine: "A few spots that look private — worth a quick check, not a failure.",
                     headline: "\(possible) possible reference\(possible == 1 ? "" : "s") to review.")
    }
}
