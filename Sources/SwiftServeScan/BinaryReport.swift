import Foundation
import SwiftServeCore

/// The canonical output of a binary scan — same pattern as the web Scoop: JSON is
/// the source of truth, the terminal card renders from it, a future Action consumes it.
public struct BinaryReport: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let target: Target
    public let swiftee: Verdict
    public let summary: Summary
    public let findings: [Finding]
    public let warnings: [String]
    public let denylist: DenylistInfo

    public static let currentVersion = 1

    public init(generatedAt: String, target: Target, swiftee: Verdict, summary: Summary,
                findings: [Finding], warnings: [String], denylist: DenylistInfo) {
        self.reportVersion = BinaryReport.currentVersion
        self.generatedAt = generatedAt
        self.target = target
        self.swiftee = swiftee
        self.summary = summary
        self.findings = findings
        self.warnings = warnings
        self.denylist = denylist
    }

    public struct Target: Codable, Sendable, Equatable {
        public let path: String
        public let kind: String                 // machO | app | framework | dylib
        public let architectures: [String]
        public let binariesScanned: [String]
        public init(path: String, kind: String, architectures: [String], binariesScanned: [String]) {
            self.path = path; self.kind = kind
            self.architectures = architectures; self.binariesScanned = binariesScanned
        }
    }

    /// Swiftee's reaction — kept in the same vocabulary as the web card.
    public struct Verdict: Codable, Sendable, Equatable {
        public let mood: Mood
        public let voiceLine: String
        public let headline: String
        public init(mood: Mood, voiceLine: String, headline: String) {
            self.mood = mood; self.voiceLine = voiceLine; self.headline = headline
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let findingCount: Int
        public let high: Int
        public let medium: Int
        public let low: Int
        public init(findings: [Finding]) {
            findingCount = findings.count
            high = findings.filter { $0.severity == .high }.count
            medium = findings.filter { $0.severity == .medium }.count
            low = findings.filter { $0.severity == .low }.count
        }
    }

    public struct DenylistInfo: Codable, Sendable, Equatable {
        public let version: Int
        public let entryCount: Int
        public init(version: Int, entryCount: Int) {
            self.version = version; self.entryCount = entryCount
        }
    }
}

/// Maps findings to Swiftee's mood + voice. Warm, never alarmist.
public enum BinaryVerdict {
    public static func make(findings: [Finding]) -> BinaryReport.Verdict {
        let highs = findings.filter { $0.severity == .high }.count
        if findings.isEmpty {
            return .init(
                mood: .partyMode,
                voiceLine: "Clean as a fresh scoop — no private symbols in sight.",
                headline: "No references to known private Apple symbols.")
        }
        let n = findings.count
        let refs = "\(n) private-symbol reference\(n == 1 ? "" : "s")"
        if highs > 0 {
            return .init(
                mood: .meltdown,
                voiceLine: "This'll trip App Review. Let's fix it before you submit.",
                headline: "\(refs) — \(highs) high severity.")
        }
        return .init(
            mood: .softSqueeze,
            voiceLine: "A couple of things worth a look before you ship.",
            headline: "\(refs) to review.")
    }
}
