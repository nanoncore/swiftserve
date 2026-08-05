import Foundation
import SwiftServeCapability
import SwiftServeCore

public struct ReceiptBuildContext: Sendable {
    public let policy: ReceiptPolicy
    public let policySource: String
    public let enrichment: [String: EnrichmentData]
    public let enrichmentSource: String
    public let networkUsed: Bool
    public let capabilityDataset: CapabilityDataset?
    /// When rechecking is requested, the I/O layer supplies deterministic
    /// results keyed by normalized package identity.
    public let recheckedCapabilities: [String: [CapabilityImpact]]
    public let capabilityRecheckRequested: Bool
    public let capabilityRecheckExecuted: Bool
    public let unavailablePackages: [String]

    public init(policy: ReceiptPolicy = .default, policySource: String = "default",
                enrichment: [String: EnrichmentData] = [:], enrichmentSource: String = "fileOnly",
                networkUsed: Bool = false, capabilityDataset: CapabilityDataset? = nil,
                recheckedCapabilities: [String: [CapabilityImpact]] = [:],
                capabilityRecheckRequested: Bool = false,
                capabilityRecheckExecuted: Bool = false,
                unavailablePackages: [String] = []) {
        self.policy = policy
        self.policySource = policySource
        self.enrichment = enrichment
        self.enrichmentSource = enrichmentSource
        self.networkUsed = networkUsed
        self.capabilityDataset = capabilityDataset
        self.recheckedCapabilities = recheckedCapabilities
        self.capabilityRecheckRequested = capabilityRecheckRequested
        self.capabilityRecheckExecuted = capabilityRecheckExecuted
        self.unavailablePackages = unavailablePackages
    }
}

public enum ReceiptEngine {
    public static func build(base: [Pin], head: [Pin], generatedAt: String,
                             context: ReceiptBuildContext = ReceiptBuildContext()) -> UpgradeReceipt {
        let baseGroups = groups(base)
        let headGroups = groups(head)
        let identities = Set(baseGroups.keys).union(headGroups.keys).sorted()
        var changes: [UpgradeChange] = []

        for identity in identities {
            let oldPins = baseGroups[identity] ?? []
            let newPins = headGroups[identity] ?? []
            if let change = makeChange(identity: identity, oldPins: oldPins, newPins: newPins,
                                       context: context) {
                changes.append(change)
            }
        }

        let requiredViolations = requiredCapabilityViolations(
            head: head, changes: changes, context: context)
        var policyViolations = changes.flatMap(\.findings)
            .filter { $0.severity >= .review }
            .map { $0.code.rawValue }
        policyViolations.append(contentsOf: requiredViolations
            .filter { $0.severity >= .review }
            .map(\.identifier))
        policyViolations = Array(Set(policyViolations)).sorted()

        let highest = (changes.map(\.severity) + requiredViolations.map(\.severity)).max() ?? .info
        let verdict: ReceiptVerdict
        if highest == .block { verdict = .block }
        else if highest == .review { verdict = .review }
        else { verdict = .pass }

        let policy = ReceiptPolicyEvaluation(
            source: context.policySource, version: context.policy.version,
            passed: verdict == .pass, violations: policyViolations)
        let enrichment = ReceiptEnrichmentInfo(
            source: context.enrichmentSource, networkUsed: context.networkUsed,
            capabilityRecheckRequested: context.capabilityRecheckRequested,
            capabilityRecheckExecuted: context.capabilityRecheckExecuted,
            unavailablePackages: context.unavailablePackages)

        return UpgradeReceipt(
            generatedAt: generatedAt, verdict: verdict,
            headline: headline(verdict: verdict, changeCount: changes.count),
            base: summary(base), head: summary(head), changes: changes,
            policy: policy, enrichment: enrichment)
    }

    // MARK: - Change detection

    private static func makeChange(identity: String, oldPins: [Pin], newPins: [Pin],
                                   context: ReceiptBuildContext) -> UpgradeChange? {
        let old = oldPins.sorted(by: pinOrder).first
        let new = newPins.sorted(by: pinOrder).first
        var codes: [(FindingCode, String)] = []
        var changeType: ReceiptChangeType = .modified
        var classification: UpdateClassification = .unknown

        if old == nil {
            changeType = .added
            classification = .added
            codes.append((.packageAdded, "\(identity) was added."))
        } else if new == nil {
            changeType = .removed
            classification = .removed
            codes.append((.packageRemoved, "\(identity) was removed."))
        } else if let old, let new {
            let oldSource = RepoIdentity.canonicalURL(old.location)
            let newSource = RepoIdentity.canonicalURL(new.location)
            let sourceChanged = oldSource != newSource || old.kind != new.kind
            if sourceChanged {
                classification = .sourceChanged
                codes.append((.sourceChange, "Repository source changed from \(RepoIdentity.redactedLocation(old.location)) to \(RepoIdentity.redactedLocation(new.location))."))
            }
            if old.pinType != new.pinType {
                if classification == .unknown { classification = .pinType }
                codes.append((.pinTypeChange, "Pin type changed from \(old.pinType.rawValue) to \(new.pinType.rawValue)."))
            }

            classifyVersions(old: old, new: new, changeType: &changeType,
                             classification: &classification, codes: &codes)
            if sourceChanged { classification = .sourceChanged }

            if old.revision != new.revision,
               old.resolvedVersion == new.resolvedVersion,
               old.pinType == new.pinType {
                if classification == .unknown { classification = .revisionChanged }
                codes.append((.revisionChange, "Revision changed beneath the same pin value."))
            }

            if codes.isEmpty, old == new, oldPins.count == newPins.count,
               oldPins.count <= 1 { return nil }
            if classification == .unknown, !codes.contains(where: { $0.0 == .unknownVersion }) {
                classification = .metadataOnly
            }
        }

        if let new, new.pinType == .branch {
            if classification == .unknown { classification = .branch }
            codes.append((.branchPin, "Head is pinned to branch \(new.branch ?? "<unknown>")."))
        } else if let new, new.pinType == .revision {
            if classification == .unknown { classification = .revision }
            codes.append((.revisionPin, "Head is pinned directly to a revision."))
        }

        appendIdentityFindings(identity: identity, pins: oldPins, side: "base", codes: &codes)
        appendIdentityFindings(identity: identity, pins: newPins, side: "head", codes: &codes)

        var capabilityChecks = context.recheckedCapabilities[identity]
            ?? projectedCapabilities(identity: identity, old: old, new: new, dataset: context.capabilityDataset)
        capabilityChecks.sort {
            ($0.capability ?? "", $0.platform ?? "") < ($1.capability ?? "", $1.platform ?? "")
        }
        appendCapabilityFindings(capabilityChecks, codes: &codes)

        let findings = deduplicatedFindings(codes, policy: context.policy)
        let severity = findings.map(\.severity).max() ?? .info
        let healthDelta = healthDelta(identity: identity, old: old, new: new, context: context)

        return UpgradeChange(
            identity: identity, changeType: changeType, classification: classification,
            severity: severity, findings: findings,
            oldPin: old.map(PinSnapshot.init), newPin: new.map(PinSnapshot.init),
            healthDelta: healthDelta, capabilityChecks: capabilityChecks)
    }

    private static func classifyVersions(old: Pin, new: Pin, changeType: inout ReceiptChangeType,
                                         classification: inout UpdateClassification,
                                         codes: inout [(FindingCode, String)]) {
        guard old.pinType == .version, new.pinType == .version,
              let oldText = old.resolvedVersion, let newText = new.resolvedVersion else { return }
        guard oldText != newText else { return }
        guard let oldVersion = SemVer(oldText), let newVersion = SemVer(newText) else {
            changeType = .unknown
            classification = .unknown
            codes.append((.unknownVersion, "Version change \(oldText) → \(newText) is not semantic and was not guessed."))
            return
        }

        if oldVersion < newVersion { changeType = .upgraded }
        else if newVersion < oldVersion {
            changeType = .downgraded
            codes.append((.downgrade, "Version moved backward from \(oldText) to \(newText)."))
        } else {
            changeType = .modified
            classification = .metadataOnly
        }

        if !oldVersion.prerelease, newVersion.prerelease {
            classification = .stableToPrerelease
            codes.append((.stableToPrerelease, "Stable \(oldText) changed to prerelease \(newText)."))
        } else if oldVersion.prerelease, !newVersion.prerelease {
            classification = .prereleaseToStable
            codes.append((.prereleaseToStable, "Prerelease \(oldText) changed to stable \(newText)."))
        } else if oldVersion.prerelease, newVersion.prerelease {
            classification = .prereleaseToPrerelease
            codes.append((.prereleaseChange, "Prerelease changed from \(oldText) to \(newText)."))
        } else if oldVersion.major != newVersion.major {
            classification = .major
            if changeType == .upgraded {
                codes.append((.majorUpdate, "Major version changed from \(oldText) to \(newText)."))
            }
        } else if oldVersion.minor != newVersion.minor {
            classification = .minor
            if changeType == .upgraded {
                codes.append((.minorUpdate, "Minor version changed from \(oldText) to \(newText)."))
            }
        } else if oldVersion.patch != newVersion.patch {
            classification = .patch
            if changeType == .upgraded {
                codes.append((.patchUpdate, "Patch version changed from \(oldText) to \(newText)."))
            }
        }
    }

    private static func appendIdentityFindings(identity: String, pins: [Pin], side: String,
                                               codes: inout [(FindingCode, String)]) {
        guard pins.count > 1 else { return }
        codes.append((.duplicateIdentity, "\(side) contains \(pins.count) pins for normalized identity \(identity)."))
        let states = Set(pins.map { pinFingerprint($0) })
        if states.count > 1 {
            codes.append((.conflictingIdentity, "\(side) contains conflicting pins for normalized identity \(identity)."))
        }
    }

    // MARK: - Capability projection

    private static func projectedCapabilities(identity: String, old: Pin?, new: Pin?,
                                              dataset: CapabilityDataset?) -> [CapabilityImpact] {
        guard let dataset else { return [] }
        let location = new?.location ?? old?.location ?? identity
        let canonical = RepoIdentity.canonicalURL(location)
        let records = dataset.records.filter { record in
            record.package.canonicalURL == canonical
                || record.package.name.lowercased() == identity
                || record.package.aliases.contains { $0.lowercased() == identity }
        }
        guard !records.isEmpty else {
            return [.init(capability: nil, platform: nil, outcome: .notIndexed,
                          baseStatus: nil, headStatus: nil, evidenceVersion: nil,
                          detail: "No bundled capability records are indexed for this package.")]
        }
        if records.contains(where: { $0.package.firstParty }) {
            return [.init(capability: nil, platform: nil, outcome: .firstPartySkipped,
                          baseStatus: nil, headStatus: nil, evidenceVersion: nil,
                          detail: "First-party SDK records are not dependency release pins.")]
        }

        return records.sorted { $0.capability.id < $1.capability.id }.flatMap { record in
            record.platforms.keys.sorted().map { platform in
                let claim = record.platforms[platform]!
                let baseExact = old.map { recordMatches(pin: $0, record: record) } ?? false
                let headExact = new.map { recordMatches(pin: $0, record: record) } ?? false
                let evidence = evidence(for: claim, record: record, dataset: dataset)
                if headExact {
                    return CapabilityImpact(
                        capability: record.capability.id, platform: platform, outcome: .exactEvidence,
                        baseStatus: baseExact ? claim.status : nil, headStatus: claim.status,
                        evidenceVersion: record.package.version,
                        detail: "Bundled evidence exactly matches head version \(record.package.version).",
                        evidence: evidence)
                }
                return CapabilityImpact(
                    capability: record.capability.id, platform: platform, outcome: .unverified,
                    baseStatus: baseExact ? claim.status : nil, headStatus: nil,
                    evidenceVersion: baseExact ? record.package.version : nil,
                    detail: "No bundled evidence exactly matches the head version and revision; no claim was extrapolated.",
                    evidence: baseExact ? evidence : [])
            }
        }
    }

    private static func evidence(for claim: PlatformClaim, record: CapabilityRecord,
                                 dataset: CapabilityDataset) -> [ReceiptEvidence] {
        claim.evidence.map { anchor in
            let target = anchor.package ?? record.package.canonicalURL
            let permalink: String?
            if let file = anchor.file, let line = anchor.line,
               RepoIdentity.ownerRepo(from: target) != nil {
                let tag = dataset.records.first { $0.package.canonicalURL == target }?.package.version
                    ?? record.package.version
                permalink = "\(target)/blob/\(tag)/\(file)#L\(line)"
            } else { permalink = nil }
            return ReceiptEvidence(kind: anchor.kind.rawValue, symbol: anchor.symbol,
                                   file: anchor.file, line: anchor.line,
                                   condition: anchor.condition, permalink: permalink)
        }
    }

    private static func appendCapabilityFindings(_ checks: [CapabilityImpact],
                                                 codes: inout [(FindingCode, String)]) {
        for check in checks {
            let code: FindingCode? = switch check.outcome {
            case .exactEvidence: nil
            case .stillTrue: .capabilityStillTrue
            case .truthChanged: .capabilityTruthChanged
            case .anchorGone: .capabilityAnchorGone
            case .needsProbe: .capabilityNeedsProbe
            case .unavailable: .capabilityUnavailable
            case .unverified: .capabilityUnverified
            case .notIndexed: .capabilityNotIndexed
            case .firstPartySkipped: .capabilityFirstPartySkipped
            }
            if let code { codes.append((code, check.detail)) }
        }
    }

    private static func recordMatches(pin: Pin, record: CapabilityRecord) -> Bool {
        guard pin.pinType == .version, let version = pin.resolvedVersion else { return false }
        let sameVersion = version == record.package.version
            || (SemVer(version) != nil && SemVer(version) == SemVer(record.package.version))
        guard sameVersion else { return false }
        guard let revision = pin.revision, !revision.isEmpty, !record.package.commit.isEmpty else { return true }
        return revision.caseInsensitiveCompare(record.package.commit) == .orderedSame
    }

    // MARK: - Policy requirements and enrichment

    private struct RequiredCapabilityViolation {
        let identifier: String
        let severity: ReceiptSeverity
    }

    private static func requiredCapabilityViolations(head: [Pin], changes: [UpgradeChange],
                                                     context: ReceiptBuildContext) -> [RequiredCapabilityViolation] {
        context.policy.requiredCapabilities.compactMap { requirement in
            let requestedIdentity = RepoIdentity.normalizedPackageIdentity(requirement.package)
            guard let pin = head.first(where: {
                RepoIdentity.normalizedPackageIdentity($0.identity) == requestedIdentity
                    || RepoIdentity.canonicalURL($0.location) == RepoIdentity.canonicalURL(requirement.package)
            }) else {
                let code = FindingCode.requiredCapabilityMismatch
                let safePackage = RepoIdentity.normalizedPackageIdentity(
                    RepoIdentity.redactedLocation(requirement.package))
                return RequiredCapabilityViolation(
                    identifier: "\(code.rawValue):\(safePackage):missing-package",
                    severity: context.policy.severity(for: code))
            }
            let identity = RepoIdentity.normalizedPackageIdentity(pin.identity)
            let changeChecks = changes.first { $0.identity == RepoIdentity.normalizedPackageIdentity(pin.identity) }?.capabilityChecks ?? []
            let directChecks = changeChecks.isEmpty
                ? projectedCapabilities(identity: RepoIdentity.normalizedPackageIdentity(pin.identity), old: pin,
                                        new: pin, dataset: context.capabilityDataset)
                : changeChecks
            guard let result = directChecks.first(where: {
                $0.capability == requirement.capability && $0.platform == canonicalPlatform(requirement.platform)
            }), let status = result.headStatus else {
                let code = FindingCode.requiredCapabilityUnverified
                return RequiredCapabilityViolation(
                    identifier: "\(code.rawValue):\(identity):\(requirement.capability):\(requirement.platform)",
                    severity: context.policy.severity(for: code))
            }
            guard status == requirement.expect else {
                let code = FindingCode.requiredCapabilityMismatch
                return RequiredCapabilityViolation(
                    identifier: "\(code.rawValue):\(identity):\(requirement.capability):\(requirement.platform)",
                    severity: context.policy.severity(for: code))
            }
            return nil
        }
    }

    private static func healthDelta(identity: String, old: Pin?, new: Pin?,
                                    context: ReceiptBuildContext) -> ReceiptHealthDelta? {
        guard let old, let new, let data = context.enrichment[identity] else { return nil }
        let scorer = Scorer()
        let base = scorer.score(pin: old, data: data)
        let head = scorer.score(pin: new, data: data)
        return ReceiptHealthDelta(baseScore: base.score, headScore: head.score,
                                  latestVersion: data.latestVersion)
    }

    // MARK: - Small helpers

    private static func groups(_ pins: [Pin]) -> [String: [Pin]] {
        Dictionary(grouping: pins, by: { RepoIdentity.normalizedPackageIdentity($0.identity) })
    }

    private static func summary(_ pins: [Pin]) -> ReceiptInputSummary {
        let grouped = groups(pins)
        let duplicates = grouped.filter { $0.value.count > 1 }.keys.sorted()
        let conflicts = grouped.filter { Set($0.value.map(pinFingerprint)).count > 1 }.keys.sorted()
        return ReceiptInputSummary(packageCount: pins.count, duplicateIdentities: duplicates,
                                   conflictingIdentities: conflicts)
    }

    private static func pinFingerprint(_ pin: Pin) -> String {
        [pin.kind.rawValue, RepoIdentity.canonicalURL(pin.location), pin.pinType.rawValue,
         pin.resolvedVersion ?? "", pin.branch ?? "", pin.revision ?? ""].joined(separator: "|")
    }

    private static func pinOrder(_ lhs: Pin, _ rhs: Pin) -> Bool {
        pinFingerprint(lhs) < pinFingerprint(rhs)
    }

    private static func deduplicatedFindings(_ values: [(FindingCode, String)],
                                            policy: ReceiptPolicy) -> [ReceiptFinding] {
        var seen = Set<FindingCode>()
        return values.compactMap { code, message in
            guard seen.insert(code).inserted else { return nil }
            return ReceiptFinding(code: code, severity: policy.severity(for: code), message: message)
        }.sorted { $0.code.rawValue < $1.code.rawValue }
    }

    private static func headline(verdict: ReceiptVerdict, changeCount: Int) -> String {
        if changeCount == 0 {
            return switch verdict {
            case .pass: "No dependency changes detected; configured policy passed."
            case .review: "No dependency changes detected; review requested by policy."
            case .block: "No dependency changes detected; blocked by policy."
            }
        }
        let noun = changeCount == 1 ? "change" : "changes"
        switch verdict {
        case .pass: return "\(changeCount) dependency \(noun); no configured policy violation."
        case .review: return "\(changeCount) dependency \(noun); review requested by policy."
        case .block: return "\(changeCount) dependency \(noun); blocked by policy."
        }
    }

    private static func canonicalPlatform(_ value: String) -> String {
        Platform.allCases.first { $0.rawValue.lowercased() == value.lowercased() }?.rawValue ?? value
    }

}
