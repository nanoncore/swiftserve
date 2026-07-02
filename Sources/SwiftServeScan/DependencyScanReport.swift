import Foundation
import SwiftServeCore

/// Coverage status of a scan unit (your code, or one dependency).
public enum ScanStatus: String, Codable, Sendable, Equatable {
    case scanned     // we found and scanned a compiled artifact
    case notBuilt    // a binary dep whose artifact isn't present yet (build/resolve first)
    case sourceOnly  // a source dep — not separately scanned by the binary pass
}

/// One thing we set out to scan, with its identity + coverage — declared by the
/// CLI *before* findings are counted, so 0-issue and not-scanned units still show.
public struct ScanUnit: Sendable, Equatable {
    public let kind: OriginKind
    public let identity: String?
    public let version: String?
    public let status: ScanStatus
    public let artifacts: [String]
    public init(kind: OriginKind, identity: String? = nil, version: String? = nil,
                status: ScanStatus, artifacts: [String] = []) {
        self.kind = kind; self.identity = identity; self.version = version
        self.status = status; self.artifacts = artifacts
    }
}

/// Per-group summary: "your code", a named dependency, or unattributed.
public struct DependencyRollup: Codable, Sendable, Equatable {
    public let kind: OriginKind
    public let identity: String?
    public let version: String?
    public let status: ScanStatus
    public let findingCount: Int
    public let high: Int
    public let medium: Int
    public let low: Int
    public let artifacts: [String]

    public init(kind: OriginKind, identity: String?, version: String?, status: ScanStatus,
                findingCount: Int, high: Int, medium: Int, low: Int, artifacts: [String]) {
        self.kind = kind; self.identity = identity; self.version = version; self.status = status
        self.findingCount = findingCount; self.high = high; self.medium = medium; self.low = low
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case kind, identity, version, status, findingCount, high, medium, low, artifacts
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(identity, forKey: .identity)
        try c.encode(version, forKey: .version)
        try c.encode(status, forKey: .status)
        try c.encode(findingCount, forKey: .findingCount)
        try c.encode(high, forKey: .high)
        try c.encode(medium, forKey: .medium)
        try c.encode(low, forKey: .low)
        try c.encode(artifacts, forKey: .artifacts)
    }

    /// Build rollups from the declared scan units + the findings. Units with zero
    /// findings still appear; any finding not covered by a unit is bucketed too
    /// (so nothing is dropped). First-party first, dependencies by severity, then
    /// unattributed.
    public static func build(units: [ScanUnit], findings: [Finding]) -> [DependencyRollup] {
        func key(_ kind: OriginKind, _ identity: String?) -> String {
            switch kind {
            case .firstParty: "fp"
            case .dependency: "dep:\(identity ?? "?")"
            case .unattributed: "un"
            }
        }

        // Seed accumulators from declared units.
        struct Acc { var unit: ScanUnit; var findings: [Finding] }
        var order: [String] = []
        var accs: [String: Acc] = [:]
        for unit in units {
            let k = key(unit.kind, unit.identity)
            if accs[k] == nil { order.append(k); accs[k] = Acc(unit: unit, findings: []) }
        }

        // Assign findings to their unit, synthesizing a unit if undeclared.
        for f in findings {
            let k = key(f.origin.kind, f.origin.dependency)
            if accs[k] == nil {
                order.append(k)
                accs[k] = Acc(unit: ScanUnit(kind: f.origin.kind, identity: f.origin.dependency,
                                             version: f.origin.version, status: .scanned,
                                             artifacts: f.origin.artifact.map { [$0] } ?? []), findings: [])
            }
            accs[k]?.findings.append(f)
        }

        let rollups = order.compactMap { k -> DependencyRollup? in
            guard let acc = accs[k] else { return nil }
            let fs = acc.findings
            return DependencyRollup(
                kind: acc.unit.kind, identity: acc.unit.identity, version: acc.unit.version,
                status: acc.unit.status, findingCount: fs.count,
                high: fs.filter { $0.severity == .high }.count,
                medium: fs.filter { $0.severity == .medium }.count,
                low: fs.filter { $0.severity == .low }.count,
                artifacts: acc.unit.artifacts)
        }

        // first-party, then dependencies (most-severe first), then unattributed.
        func bucket(_ k: OriginKind) -> Int { switch k { case .firstParty: 0; case .dependency: 1; case .unattributed: 2 } }
        return rollups.sorted {
            if bucket($0.kind) != bucket($1.kind) { return bucket($0.kind) < bucket($1.kind) }
            if $0.high != $1.high { return $0.high > $1.high }
            if $0.findingCount != $1.findingCount { return $0.findingCount > $1.findingCount }
            return ($0.identity ?? "") < ($1.identity ?? "")
        }
    }
}

/// The canonical output of a transitive dependency scan.
public struct DependencyScanReport: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let generatedAt: String
    public let target: Target
    public let swiftee: BinaryReport.Verdict
    public let summary: Summary
    public let dependencies: [DependencyRollup]
    public let findings: [Finding]
    public let warnings: [String]
    public let denylist: BinaryReport.DenylistInfo

    public static let currentVersion = 1

    public init(generatedAt: String, target: Target, swiftee: BinaryReport.Verdict, summary: Summary,
                dependencies: [DependencyRollup], findings: [Finding], warnings: [String],
                denylist: BinaryReport.DenylistInfo) {
        self.reportVersion = DependencyScanReport.currentVersion
        self.generatedAt = generatedAt; self.target = target; self.swiftee = swiftee
        self.summary = summary; self.dependencies = dependencies; self.findings = findings
        self.warnings = warnings; self.denylist = denylist
    }

    public struct Target: Codable, Sendable, Equatable {
        public let path: String
        public let project: String?
        public let sourcePackages: String?
        public let appBinary: String?
        public init(path: String, project: String?, sourcePackages: String?, appBinary: String?) {
            self.path = path; self.project = project
            self.sourcePackages = sourcePackages; self.appBinary = appBinary
        }
        enum CodingKeys: String, CodingKey { case path, project, sourcePackages, appBinary }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(project, forKey: .project)
            try c.encode(sourcePackages, forKey: .sourcePackages)
            try c.encode(appBinary, forKey: .appBinary)
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let findingCount: Int
        public let firstParty: Int
        public let dependency: Int
        public let unattributed: Int
        public init(findings: [Finding]) {
            findingCount = findings.count
            firstParty = findings.filter { $0.origin.kind == .firstParty }.count
            dependency = findings.filter { $0.origin.kind == .dependency }.count
            unattributed = findings.filter { $0.origin.kind == .unattributed }.count
        }
    }
}

extension BinaryVerdict {
    /// Verdict for a transitive scan — when it's a dependency's fault, the copy is
    /// relief, not a scolding.
    public static func makeDeps(findings: [Finding]) -> BinaryReport.Verdict {
        let highs = findings.filter { $0.severity == .high }
        if findings.isEmpty {
            return .init(mood: .partyMode,
                         voiceLine: "Clean scoop — no private symbols in your code or your dependencies.",
                         headline: "No references to known private Apple symbols.")
        }
        let depHighs = highs.filter { $0.origin.kind == .dependency }.count
        let n = findings.count
        let refs = "\(n) private-symbol reference\(n == 1 ? "" : "s")"
        if !highs.isEmpty {
            let tail = depHighs == highs.count
                ? " — and not all of it is your code."
                : "."
            return .init(mood: .meltdown,
                         voiceLine: "Private-API usage that App Review will flag\(tail)",
                         headline: "\(refs), \(highs.count) high severity.")
        }
        return .init(mood: .softSqueeze,
                     voiceLine: "A few private-symbol references worth a look before you ship.",
                     headline: "\(refs) to review.")
    }
}
