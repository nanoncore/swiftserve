import Foundation
import SwiftServeCore

// The query layer: dataset in, verdict out. Pure — the CLI loads the bundled
// dataset (or an override) and prints; agents read the same canonical JSON.

/// Everything a query needs, shipped as one bundled JSON: the taxonomy plus
/// every validated record. Produced by `swiftserve index assemble`.
public struct CapabilityDataset: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let datasetVersion: Int
    public let taxonomy: Taxonomy
    public let records: [CapabilityRecord]

    public init(datasetVersion: Int = CapabilityDataset.currentVersion,
                taxonomy: Taxonomy, records: [CapabilityRecord]) {
        self.datasetVersion = datasetVersion
        self.taxonomy = taxonomy
        self.records = records
    }

    public static func decode(from data: Data) throws -> CapabilityDataset {
        try JSONDecoder().decode(CapabilityDataset.self, from: data)
    }

    /// Resolve a package query — URL, owner/repo, bare name, or alias.
    public func packageRecords(matching query: String) -> [CapabilityRecord] {
        let q = query.lowercased()
        let canonical = RepoIdentity.canonicalURL(query)
        return records.filter { record in
            record.package.canonicalURL == canonical
                || record.package.canonicalURL.contains(q)
                || record.package.name.lowercased() == q
                || record.package.aliases.contains { $0.lowercased() == q }
        }
    }

    /// Resolve a capability query — exact id/label/alias first, then a
    /// forgiving substring pass ("audio session" → audio.session-management).
    public func capability(matching query: String) -> Taxonomy.Capability? {
        let q = normalize(query)
        if let exact = taxonomy.capabilities.first(where: { normalize($0.id) == q }) { return exact }
        if let byLabel = taxonomy.capabilities.first(where: { normalize($0.label) == q }) { return byLabel }
        if let byAlias = taxonomy.capabilities.first(where: { $0.aliases?.contains { normalize($0) == q } ?? false }) {
            return byAlias
        }
        return taxonomy.capabilities.first { capability in
            normalize(capability.id).contains(q) || normalize(capability.label).contains(q)
                || (capability.aliases?.contains { normalize($0).contains(q) } ?? false)
        }
    }

    /// Lowercase, and collapse separators so "session-management",
    /// "session management", and "session.management" all meet in the middle.
    private func normalize(_ s: String) -> String {
        s.lowercased().map { $0 == "-" || $0 == "." || $0 == "_" || $0 == " " ? "~" : $0 }
            .map(String.init).joined()
    }
}

/// One evidence anchor, enriched with the GitHub permalink that lets a human
/// (or an agent) jump to the exact line that decides the verdict.
public struct CheckEvidence: Codable, Sendable, Equatable {
    public let kind: String
    public let symbol: String?
    public let file: String?
    public let line: Int?
    public let condition: String?
    public let note: String?
    public let permalink: String?

    init(anchor: EvidenceAnchor, homeURL: String, homeTag: String, dataset: CapabilityDataset) {
        kind = anchor.kind.rawValue
        symbol = anchor.symbol
        file = anchor.file
        line = anchor.line
        condition = anchor.condition
        note = anchor.note
        let targetURL = anchor.package ?? homeURL
        // A companion anchor pins at the companion's own recorded version when
        // we have it; otherwise fall back to the home tag.
        let targetTag = anchor.package.flatMap { url in
            dataset.records.first { $0.package.canonicalURL == url }?.package.version
        } ?? homeTag
        if let file = anchor.file, let line = anchor.line,
           RepoIdentity.ownerRepo(from: targetURL) != nil {
            permalink = "\(targetURL)/blob/\(targetTag)/\(file)#L\(line)"
        } else {
            permalink = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(file, forKey: .file)
        try c.encode(line, forKey: .line)
        try c.encode(condition, forKey: .condition)
        try c.encode(note, forKey: .note)
        try c.encode(permalink, forKey: .permalink)
    }

    private enum CodingKeys: String, CodingKey { case kind, symbol, file, line, condition, note, permalink }
}

/// The single-question answer: does PACKAGE serve CAPABILITY on PLATFORM?
public struct CheckReport: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Query: Codable, Sendable, Equatable {
        public let package: String        // canonical URL, resolved
        public let packageName: String
        public let capability: String     // taxonomy id, resolved
        public let capabilityLabel: String
        public let platform: String
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public let status: ClaimStatus
        public let confidence: Double
        public let version: String        // "as of 2.15.1"
        public let commit: String
    }

    public struct Alternative: Codable, Sendable, Equatable {
        public let package: String
        public let packageName: String
        public let status: ClaimStatus
        public let confidence: Double
    }

    public struct Swiftee: Codable, Sendable, Equatable {
        public let mood: Mood
        public let voiceLine: String
        public let headline: String
    }

    public let reportVersion: Int
    public let query: Query
    public let verdict: Verdict
    public let evidence: [CheckEvidence]
    /// The near-miss data: this capability's status on every other platform.
    public let otherPlatforms: [String: String]
    /// Packages (with their own records) that DO serve this on the platform.
    public let alternatives: [Alternative]
    public let requiresCompanion: [String]
    public let notes: String?
    public let swiftee: Swiftee
}

public enum CapabilityQuery {

    public enum QueryError: Error, CustomStringConvertible {
        case unknownPackage(String)
        case unknownCapability(String)
        case noRecord(package: String, capability: String)

        public var description: String {
            switch self {
            case .unknownPackage(let q):
                "no records for package ‘\(q)’ — it may not be indexed yet"
            case .unknownCapability(let q):
                "no capability matches ‘\(q)’ — try `swiftserve find` or check the taxonomy"
            case .noRecord(let package, let capability):
                "\(package) has no record for \(capability) — honest answer: not verified yet"
            }
        }
    }

    public static func check(dataset: CapabilityDataset, package packageQuery: String,
                             capability capabilityQuery: String, platform: Platform) throws -> CheckReport {
        guard let capability = dataset.capability(matching: capabilityQuery) else {
            throw QueryError.unknownCapability(capabilityQuery)
        }
        let packageRecords = dataset.packageRecords(matching: packageQuery)
        guard !packageRecords.isEmpty else {
            throw QueryError.unknownPackage(packageQuery)
        }
        guard let record = packageRecords.first(where: { $0.capability.id == capability.id }) else {
            throw QueryError.noRecord(package: packageRecords[0].package.name, capability: capability.id)
        }

        let claim = record.platforms[platform.rawValue]
            ?? PlatformClaim(status: .unknown, confidence: 0, evidence: [])

        var otherPlatforms: [String: String] = [:]
        for (key, value) in record.platforms where key != platform.rawValue {
            otherPlatforms[key] = value.status.rawValue
        }

        let alternatives = dataset.records
            .filter {
                $0.capability.id == capability.id
                    && $0.package.canonicalURL != record.package.canonicalURL
                    && $0.platforms[platform.rawValue]?.status == .supported
            }
            .sorted { ($0.platforms[platform.rawValue]?.confidence ?? 0) > ($1.platforms[platform.rawValue]?.confidence ?? 0) }
            .map {
                CheckReport.Alternative(package: $0.package.canonicalURL, packageName: $0.package.name,
                                        status: .supported,
                                        confidence: $0.platforms[platform.rawValue]?.confidence ?? 0)
            }

        return CheckReport(
            reportVersion: CheckReport.currentVersion,
            query: .init(package: record.package.canonicalURL, packageName: record.package.name,
                         capability: capability.id, capabilityLabel: capability.label,
                         platform: platform.rawValue),
            verdict: .init(status: claim.status, confidence: claim.confidence,
                           version: record.package.version, commit: record.package.commit),
            evidence: claim.evidence.map {
                CheckEvidence(anchor: $0, homeURL: record.package.canonicalURL,
                              homeTag: record.package.version, dataset: dataset)
            },
            otherPlatforms: otherPlatforms,
            alternatives: alternatives,
            requiresCompanion: record.requiresCompanion,
            notes: record.notes,
            swiftee: swiftee(for: claim.status, record: record, capability: capability,
                             platform: platform, alternatives: alternatives))
    }

    /// Mood reflects the USER's situation — found / near-miss / unverified —
    /// and the copy never scolds a package; verdicts are facts pinned to a
    /// version, with the receipt one field away.
    private static func swiftee(for status: ClaimStatus, record: CapabilityRecord,
                                capability: Taxonomy.Capability, platform: Platform,
                                alternatives: [CheckReport.Alternative]) -> CheckReport.Swiftee {
        let servedElsewhere = record.platforms
            .filter { $0.key != platform.rawValue && $0.value.status == .supported }
            .keys.sorted()
        switch status {
        case .supported:
            return .init(mood: .freshSwirl,
                         voiceLine: "On the menu.",
                         headline: "\(record.package.name) serves \(capability.label.lowercased()) on \(platform.rawValue) — as of \(record.package.version).")
        case .conditional:
            return .init(mood: .softSqueeze,
                         voiceLine: "Served — with conditions.",
                         headline: "\(record.package.name) serves \(capability.label.lowercased()) on \(platform.rawValue) under conditions; check the evidence.")
        case .unsupported:
            let alt = alternatives.isEmpty
                ? "" : " \(alternatives.count) other package\(alternatives.count == 1 ? "" : "s") serve\(alternatives.count == 1 ? "s" : "") it there."
            let elsewhere = servedElsewhere.isEmpty
                ? "" : " (it serves \(servedElsewhere.joined(separator: ", ")))"
            return .init(mood: .softSqueeze,
                         voiceLine: "So close — caught it before it cost you days.",
                         headline: "\(record.package.name) doesn't serve \(capability.label.lowercased()) on \(platform.rawValue)\(elsewhere) — as of \(record.package.version).\(alt)")
        case .unknown:
            return .init(mood: .dayOld,
                         voiceLine: "Honest answer: not verified yet.",
                         headline: "No verdict for \(capability.label.lowercased()) on \(platform.rawValue) — the evidence is one record away.")
        }
    }

    // MARK: - find

    public struct FindReport: Codable, Sendable, Equatable {
        public struct Row: Codable, Sendable, Equatable {
            public let package: String
            public let packageName: String
            public let status: ClaimStatus
            public let confidence: Double
            public let version: String
            public let evidenceCount: Int
        }

        public let reportVersion: Int
        public let capability: String
        public let capabilityLabel: String
        public let platform: String
        public let results: [Row]
        public let indexedPackages: Int
    }

    public static func find(dataset: CapabilityDataset, capability capabilityQuery: String,
                            platform: Platform, includeUnsupported: Bool = false) throws -> FindReport {
        guard let capability = dataset.capability(matching: capabilityQuery) else {
            throw QueryError.unknownCapability(capabilityQuery)
        }
        func weight(_ status: ClaimStatus) -> Double {
            switch status {
            case .supported: 3
            case .conditional: 2
            case .unknown: 1
            case .unsupported: 0
            }
        }
        let rows = dataset.records
            .filter { $0.capability.id == capability.id }
            .compactMap { record -> FindReport.Row? in
                let claim = record.platforms[platform.rawValue]
                    ?? PlatformClaim(status: .unknown, confidence: 0, evidence: [])
                if claim.status == .unsupported, !includeUnsupported { return nil }
                return FindReport.Row(package: record.package.canonicalURL,
                                      packageName: record.package.name,
                                      status: claim.status, confidence: claim.confidence,
                                      version: record.package.version,
                                      evidenceCount: claim.evidence.count)
            }
            .sorted {
                let a = weight($0.status) * max($0.confidence, 0.01)
                let b = weight($1.status) * max($1.confidence, 0.01)
                return a == b ? $0.packageName < $1.packageName : a > b
            }
        return FindReport(reportVersion: 1, capability: capability.id,
                          capabilityLabel: capability.label, platform: platform.rawValue,
                          results: rows,
                          indexedPackages: Set(dataset.records.map(\.package.canonicalURL)).count)
    }
}
