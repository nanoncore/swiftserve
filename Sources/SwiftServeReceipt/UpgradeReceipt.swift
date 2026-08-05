import Foundation
import SwiftServeCapability
import SwiftServeCore

public enum ReceiptVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case pass
    case review
    case block
}

public enum ReceiptSeverity: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case info
    case review
    case block

    public static func < (lhs: ReceiptSeverity, rhs: ReceiptSeverity) -> Bool {
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}

public enum ReceiptChangeType: String, Codable, Sendable, Equatable, CaseIterable {
    case added
    case removed
    case upgraded
    case downgraded
    case modified
    case unknown
}

public enum UpdateClassification: String, Codable, Sendable, Equatable, CaseIterable {
    case added
    case removed
    case major
    case minor
    case patch
    case stableToPrerelease = "stable-to-prerelease"
    case prereleaseToStable = "prerelease-to-stable"
    case prereleaseToPrerelease = "prerelease-to-prerelease"
    case branch
    case revision
    case pinType = "pin-type"
    case revisionChanged = "revision-changed"
    case sourceChanged = "source-changed"
    case metadataOnly = "metadata-only"
    case unknown
}

public enum FindingCode: String, Codable, Sendable, Equatable, CaseIterable {
    case packageAdded = "package-added"
    case packageRemoved = "package-removed"
    case majorUpdate = "major-update"
    case minorUpdate = "minor-update"
    case patchUpdate = "patch-update"
    case downgrade
    case stableToPrerelease = "stable-to-prerelease"
    case prereleaseToStable = "prerelease-to-stable"
    case prereleaseChange = "prerelease-change"
    case branchPin = "branch-pin"
    case revisionPin = "revision-pin"
    case pinTypeChange = "pin-type-change"
    case revisionChange = "revision-change"
    case sourceChange = "source-change"
    case duplicateIdentity = "duplicate-identity"
    case conflictingIdentity = "conflicting-identity"
    case unknownVersion = "unknown-version"
    case capabilityStillTrue = "capability-still-true"
    case capabilityTruthChanged = "capability-truth-changed"
    case capabilityAnchorGone = "capability-anchor-gone"
    case capabilityNeedsProbe = "capability-needs-probe"
    case capabilityUnavailable = "capability-unavailable"
    case capabilityUnverified = "capability-unverified"
    case capabilityNotIndexed = "capability-not-indexed"
    case capabilityFirstPartySkipped = "capability-first-party-skipped"
    case requiredCapabilityMismatch = "required-capability-mismatch"
    case requiredCapabilityUnverified = "required-capability-unverified"
}

public struct ReceiptFinding: Codable, Sendable, Equatable {
    public let code: FindingCode
    public let severity: ReceiptSeverity
    public let message: String

    public init(code: FindingCode, severity: ReceiptSeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

public struct PinSnapshot: Sendable, Equatable {
    public let identity: String
    public let kind: PinKind
    public let location: String
    public let pinType: PinType
    public let version: String?
    public let branch: String?
    public let revision: String?

    public init(_ pin: Pin) {
        identity = RepoIdentity.normalizedPackageIdentity(pin.identity)
        kind = pin.kind
        location = RepoIdentity.redactedLocation(pin.location)
        pinType = pin.pinType
        version = pin.resolvedVersion
        branch = pin.branch
        revision = pin.revision
    }
}

extension PinSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case identity, kind, location, pinType, version, branch, revision
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(kind, forKey: .kind)
        try c.encode(location, forKey: .location)
        try c.encode(pinType, forKey: .pinType)
        try c.encode(version, forKey: .version)
        try c.encode(branch, forKey: .branch)
        try c.encode(revision, forKey: .revision)
    }
}

public struct ReceiptHealthDelta: Codable, Sendable, Equatable {
    public let baseScore: Int
    public let headScore: Int
    public let delta: Int
    public let latestVersion: String?

    public init(baseScore: Int, headScore: Int, latestVersion: String?) {
        self.baseScore = baseScore
        self.headScore = headScore
        self.delta = headScore - baseScore
        self.latestVersion = latestVersion
    }

    private enum CodingKeys: String, CodingKey { case baseScore, headScore, delta, latestVersion }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseScore, forKey: .baseScore)
        try c.encode(headScore, forKey: .headScore)
        try c.encode(delta, forKey: .delta)
        try c.encode(latestVersion, forKey: .latestVersion)
    }
}

public enum CapabilityImpactOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case exactEvidence = "exact-evidence"
    case stillTrue = "still-true"
    case truthChanged = "truth-changed"
    case anchorGone = "anchor-gone"
    case needsProbe = "needs-probe"
    case unavailable
    case unverified
    case notIndexed = "not-indexed"
    case firstPartySkipped = "first-party-skipped"
}

public struct ReceiptEvidence: Sendable, Equatable {
    public let kind: String
    public let symbol: String?
    public let file: String?
    public let line: Int?
    public let condition: String?
    public let permalink: String?

    public init(kind: String, symbol: String?, file: String?, line: Int?, condition: String?, permalink: String?) {
        self.kind = kind
        self.symbol = symbol
        self.file = file
        self.line = line
        self.condition = condition
        self.permalink = permalink
    }
}

extension ReceiptEvidence: Codable {
    private enum CodingKeys: String, CodingKey { case kind, symbol, file, line, condition, permalink }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(file, forKey: .file)
        try c.encode(line, forKey: .line)
        try c.encode(condition, forKey: .condition)
        try c.encode(permalink, forKey: .permalink)
    }
}

public struct CapabilityImpact: Sendable, Equatable {
    public let capability: String?
    public let platform: String?
    public let outcome: CapabilityImpactOutcome
    public let baseStatus: ClaimStatus?
    public let headStatus: ClaimStatus?
    public let evidenceVersion: String?
    public let detail: String
    public let evidence: [ReceiptEvidence]

    public init(capability: String?, platform: String?, outcome: CapabilityImpactOutcome,
                baseStatus: ClaimStatus?, headStatus: ClaimStatus?, evidenceVersion: String?,
                detail: String, evidence: [ReceiptEvidence] = []) {
        self.capability = capability
        self.platform = platform
        self.outcome = outcome
        self.baseStatus = baseStatus
        self.headStatus = headStatus
        self.evidenceVersion = evidenceVersion
        self.detail = detail
        self.evidence = evidence
    }
}

extension CapabilityImpact: Codable {
    private enum CodingKeys: String, CodingKey {
        case capability, platform, outcome, baseStatus, headStatus, evidenceVersion, detail, evidence
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capability, forKey: .capability)
        try c.encode(platform, forKey: .platform)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(baseStatus, forKey: .baseStatus)
        try c.encode(headStatus, forKey: .headStatus)
        try c.encode(evidenceVersion, forKey: .evidenceVersion)
        try c.encode(detail, forKey: .detail)
        try c.encode(evidence, forKey: .evidence)
    }
}

public struct UpgradeChange: Sendable, Equatable {
    public let identity: String
    public let changeType: ReceiptChangeType
    public let classification: UpdateClassification
    public let severity: ReceiptSeverity
    public let findings: [ReceiptFinding]
    public let oldPin: PinSnapshot?
    public let newPin: PinSnapshot?
    public let healthDelta: ReceiptHealthDelta?
    public let capabilityChecks: [CapabilityImpact]

    public init(identity: String, changeType: ReceiptChangeType, classification: UpdateClassification,
                severity: ReceiptSeverity, findings: [ReceiptFinding], oldPin: PinSnapshot?,
                newPin: PinSnapshot?, healthDelta: ReceiptHealthDelta?, capabilityChecks: [CapabilityImpact]) {
        self.identity = identity
        self.changeType = changeType
        self.classification = classification
        self.severity = severity
        self.findings = findings
        self.oldPin = oldPin
        self.newPin = newPin
        self.healthDelta = healthDelta
        self.capabilityChecks = capabilityChecks
    }
}

extension UpgradeChange: Codable {
    private enum CodingKeys: String, CodingKey {
        case identity, changeType, classification, severity, findings, oldPin, newPin, healthDelta, capabilityChecks
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(changeType, forKey: .changeType)
        try c.encode(classification, forKey: .classification)
        try c.encode(severity, forKey: .severity)
        try c.encode(findings, forKey: .findings)
        try c.encode(oldPin, forKey: .oldPin)
        try c.encode(newPin, forKey: .newPin)
        try c.encode(healthDelta, forKey: .healthDelta)
        try c.encode(capabilityChecks, forKey: .capabilityChecks)
    }
}

public struct ReceiptInputSummary: Codable, Sendable, Equatable {
    public let packageCount: Int
    public let duplicateIdentities: [String]
    public let conflictingIdentities: [String]

    public init(packageCount: Int, duplicateIdentities: [String], conflictingIdentities: [String]) {
        self.packageCount = packageCount
        self.duplicateIdentities = duplicateIdentities.sorted()
        self.conflictingIdentities = conflictingIdentities.sorted()
    }
}

public struct ReceiptCounts: Codable, Sendable, Equatable {
    public struct ByChangeType: Codable, Sendable, Equatable {
        public let added, removed, upgraded, downgraded, modified, unknown: Int
    }

    public struct BySeverity: Codable, Sendable, Equatable {
        public let info, review, block: Int
    }

    public let total: Int
    public let byChangeType: ByChangeType
    public let bySeverity: BySeverity

    public init(changes: [UpgradeChange]) {
        func count(_ type: ReceiptChangeType) -> Int { changes.count { $0.changeType == type } }
        func count(_ severity: ReceiptSeverity) -> Int { changes.count { $0.severity == severity } }
        total = changes.count
        byChangeType = .init(added: count(.added), removed: count(.removed), upgraded: count(.upgraded),
                             downgraded: count(.downgraded), modified: count(.modified), unknown: count(.unknown))
        bySeverity = .init(info: count(.info), review: count(.review), block: count(.block))
    }
}

public struct ReceiptPolicyEvaluation: Codable, Sendable, Equatable {
    public let source: String
    public let version: Int
    public let passed: Bool
    public let violations: [String]

    public init(source: String, version: Int, passed: Bool, violations: [String]) {
        self.source = source
        self.version = version
        self.passed = passed
        self.violations = violations.sorted()
    }
}

public struct ReceiptEnrichmentInfo: Codable, Sendable, Equatable {
    public let source: String
    public let networkUsed: Bool
    public let capabilityRecheckRequested: Bool
    public let capabilityRecheckExecuted: Bool
    public let unavailablePackages: [String]

    public init(source: String, networkUsed: Bool, capabilityRecheckRequested: Bool,
                capabilityRecheckExecuted: Bool, unavailablePackages: [String]) {
        self.source = source
        self.networkUsed = networkUsed
        self.capabilityRecheckRequested = capabilityRecheckRequested
        self.capabilityRecheckExecuted = capabilityRecheckExecuted
        self.unavailablePackages = unavailablePackages.sorted()
    }
}

/// Canonical, versioned Upgrade Receipt. This is separate from the v1 Scoop
/// report and does not change or reinterpret that contract.
public struct UpgradeReceipt: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let receiptVersion: Int
    public let generatedAt: String
    public let verdict: ReceiptVerdict
    public let headline: String
    public let base: ReceiptInputSummary
    public let head: ReceiptInputSummary
    public let counts: ReceiptCounts
    public let changes: [UpgradeChange]
    public let policy: ReceiptPolicyEvaluation
    public let enrichment: ReceiptEnrichmentInfo

    public init(generatedAt: String, verdict: ReceiptVerdict, headline: String,
                base: ReceiptInputSummary, head: ReceiptInputSummary,
                changes: [UpgradeChange], policy: ReceiptPolicyEvaluation,
                enrichment: ReceiptEnrichmentInfo) {
        receiptVersion = Self.currentVersion
        self.generatedAt = generatedAt
        self.verdict = verdict
        self.headline = headline
        self.base = base
        self.head = head
        self.changes = changes.sorted { $0.identity < $1.identity }
        counts = ReceiptCounts(changes: changes)
        self.policy = policy
        self.enrichment = enrichment
    }
}
