import Foundation

// The self-checking index: re-verify a record's anchors against a freshly
// extracted surface at a newer tag — no LLM, no human, just the same
// deterministic facts the record was grounded in. Pure: surfaces, verdicts,
// and taxonomy come in as data; the CLI owns git and disk.

/// Where a record lands after a recheck. `upToDate`, `skipped`, and `error`
/// are assigned by the CLI (they describe the package, not the diff); the
/// engine emits the other four.
public enum RecheckOutcome: String, Codable, Sendable {
    /// Pinned tag is still the latest stable — nothing to do.
    case upToDate = "up-to-date"
    /// Every anchor holds at the new tag; the proposal carries the bump.
    case stillTrue = "still-true"
    /// An anchor resolves but its platform truth moved — a guard appeared,
    /// a fence fell. Never auto-written; this is the finding worth reading.
    case truthChanged = "truth-changed"
    /// An anchor no longer names anything we can find — renamed, removed,
    /// or now ambiguous. Never auto-written.
    case anchorGone = "anchor-gone"
    /// The record cites a build verdict that doesn't exist at the new
    /// commit — xcodebuild territory, out of recheck's reach.
    case needsProbe = "needs-probe"
    /// First-party, non-GitHub, or no stable semver tag to compare against.
    case skipped
    /// The package couldn't be rechecked (pin inconsistency, clone or
    /// extraction failure) — the report says why.
    case error
}

/// Per-anchor forensics — what happened to one piece of evidence.
public struct AnchorFinding: Codable, Sendable, Equatable {
    public enum Change: String, Codable, Sendable {
        /// Resolves exactly where the record says.
        case unchanged
        /// Same symbol, same file, new line — repaired in the proposal.
        case lineRepaired = "line-repaired"
        /// Same symbol, globally unique, new file — repaired in the proposal.
        case fileRepaired = "file-repaired"
        /// The symbol no longer exists on the new surface.
        case unresolved
        /// Same-named decls exist but none is identifiable as this anchor.
        case ambiguous
        /// Kind names no declaration (readme/manifestPlatforms/buildVerdict).
        case notApplicable = "not-applicable"
    }

    public let platform: String
    public let anchorIndex: Int         // position in claim.evidence
    public let kind: String             // EvidenceKind.rawValue
    public let symbol: String?
    public let change: Change
    /// The decl's `#if` text changed while its resolved state did not —
    /// mechanical refresh, not a truth change.
    public let conditionTextUpdated: Bool
    public let oldFile: String?
    public let oldLine: Int?
    public let newFile: String?
    public let newLine: Int?
    public let oldPresence: String?     // "present" | "absent" | "conditional"
    public let newPresence: String?
    public let detail: String?          // one human sentence when something moved

    public init(platform: String, anchorIndex: Int, kind: String, symbol: String?,
                change: Change, conditionTextUpdated: Bool,
                oldFile: String?, oldLine: Int?, newFile: String?, newLine: Int?,
                oldPresence: String?, newPresence: String?, detail: String?) {
        self.platform = platform
        self.anchorIndex = anchorIndex
        self.kind = kind
        self.symbol = symbol
        self.change = change
        self.conditionTextUpdated = conditionTextUpdated
        self.oldFile = oldFile
        self.oldLine = oldLine
        self.newFile = newFile
        self.newLine = newLine
        self.oldPresence = oldPresence
        self.newPresence = newPresence
        self.detail = detail
    }
}

/// One record's recheck: the bucket, the receipts, and — for still-true —
/// the rewritten record ready to land.
public struct RecordRecheck: Codable, Sendable {
    public let capabilityID: String
    public let outcome: RecheckOutcome
    public let reason: String
    public let anchors: [AnchorFinding]
    /// Re-validation diagnostics when they decided the outcome.
    public let diagnostics: [RecordValidator.Diagnostic]
    /// Non-nil exactly when outcome == .stillTrue.
    public let proposed: CapabilityRecord?

    public init(capabilityID: String, outcome: RecheckOutcome, reason: String,
                anchors: [AnchorFinding], diagnostics: [RecordValidator.Diagnostic],
                proposed: CapabilityRecord?) {
        self.capabilityID = capabilityID
        self.outcome = outcome
        self.reason = reason
        self.anchors = anchors
        self.diagnostics = diagnostics
        self.proposed = proposed
    }
}

/// The machine-readable output of one recheck run — the interface the cron,
/// PR, and changelog slices consume. Versioned like every other artifact.
public struct RecheckReport: Codable, Sendable {
    public static let currentVersion = 1

    public struct PackageEntry: Codable, Sendable {
        public let canonicalURL: String
        public let name: String
        /// "up-to-date" | "new-tag" | "skipped" | "error"
        public let status: String
        public let skipReason: String?   // "first-party" | "non-github" | "no-stable-tag"
        public let errorDetail: String?
        public let pinnedTag: String?
        public let pinnedCommit: String?
        public let latestTag: String?
        public let latestCommit: String?
        /// --apply actually wrote this package's bump.
        public let applied: Bool
        /// Capability ids that blocked an otherwise-applicable bump.
        public let heldBackBy: [String]
        /// Repo-relative record files inspected/touched.
        public let recordFiles: [String]
        public let records: [RecordRecheck]

        public init(canonicalURL: String, name: String, status: String,
                    skipReason: String? = nil, errorDetail: String? = nil,
                    pinnedTag: String? = nil, pinnedCommit: String? = nil,
                    latestTag: String? = nil, latestCommit: String? = nil,
                    applied: Bool = false, heldBackBy: [String] = [],
                    recordFiles: [String] = [], records: [RecordRecheck] = []) {
            self.canonicalURL = canonicalURL
            self.name = name
            self.status = status
            self.skipReason = skipReason
            self.errorDetail = errorDetail
            self.pinnedTag = pinnedTag
            self.pinnedCommit = pinnedCommit
            self.latestTag = latestTag
            self.latestCommit = latestCommit
            self.applied = applied
            self.heldBackBy = heldBackBy
            self.recordFiles = recordFiles
            self.records = records
        }
    }

    public struct Summary: Codable, Sendable {
        public let upToDate: Int
        public let stillTrue: Int
        public let truthChanged: Int
        public let anchorGone: Int
        public let needsProbe: Int
        public let skipped: Int
        public let errors: Int
        public let applied: Int

        /// Record-level tallies across all packages; `applied` counts packages.
        public init(packages: [PackageEntry]) {
            var byOutcome: [RecheckOutcome: Int] = [:]
            for entry in packages {
                if entry.status == "up-to-date" {
                    byOutcome[.upToDate, default: 0] += entry.records.count
                } else if entry.status == "skipped" {
                    byOutcome[.skipped, default: 0] += max(entry.records.count, 1)
                } else if entry.status == "error" {
                    byOutcome[.error, default: 0] += max(entry.records.count, 1)
                } else {
                    for record in entry.records {
                        byOutcome[record.outcome, default: 0] += 1
                    }
                }
            }
            upToDate = byOutcome[.upToDate] ?? 0
            stillTrue = byOutcome[.stillTrue] ?? 0
            truthChanged = byOutcome[.truthChanged] ?? 0
            anchorGone = byOutcome[.anchorGone] ?? 0
            needsProbe = byOutcome[.needsProbe] ?? 0
            skipped = byOutcome[.skipped] ?? 0
            errors = byOutcome[.error] ?? 0
            applied = packages.filter(\.applied).count
        }
    }

    public let reportVersion: Int
    /// ISO8601, injected by the CLI — the type stays clock-free and testable.
    public let generatedAt: String
    public let apply: Bool
    public let packages: [PackageEntry]
    public let summary: Summary

    public init(generatedAt: String, apply: Bool, packages: [PackageEntry]) {
        self.reportVersion = Self.currentVersion
        self.generatedAt = generatedAt
        self.apply = apply
        self.packages = packages.sorted { $0.canonicalURL < $1.canonicalURL }
        self.summary = Summary(packages: packages)
    }
}

/// Buckets one record against a freshly extracted surface. Pure.
public enum RecheckEngine {

    public struct Input: Sendable {
        public let record: CapabilityRecord
        /// Home surface at the pinned tag + companions at their lock pins.
        public let oldSurfaces: [String: PackageSurface]
        /// Home surface at the new tag + the same companion objects
        /// (companions bump in their own rechecks, never here).
        public let newSurfaces: [String: PackageSurface]
        /// Canonical URL → fnv1a64 of the NEW surface JSON bytes.
        public let newDigests: [String: String]
        public let newTag: String
        public let newCommit: String
        /// Keyed by `BuildVerdict.key(canonicalURL:platform:)`.
        public let buildVerdicts: [String: BuildVerdict]
        public let taxonomy: Taxonomy

        public init(record: CapabilityRecord, oldSurfaces: [String: PackageSurface],
                    newSurfaces: [String: PackageSurface], newDigests: [String: String],
                    newTag: String, newCommit: String,
                    buildVerdicts: [String: BuildVerdict] = [:], taxonomy: Taxonomy) {
            self.record = record
            self.oldSurfaces = oldSurfaces
            self.newSurfaces = newSurfaces
            self.newDigests = newDigests
            self.newTag = newTag
            self.newCommit = newCommit
            self.buildVerdicts = buildVerdicts
            self.taxonomy = taxonomy
        }
    }

    public static func recheck(_ input: Input) -> RecordRecheck {
        let record = input.record
        let home = record.package.canonicalURL

        // 1 — needs-probe gate. Build verdicts are whole-package proof pinned
        // to a commit; recheck can't re-probe (xcodebuild), so a record that
        // leans on one is only bumpable once a conclusive verdict exists at
        // the NEW commit. Conclusive fresh verdicts fall through — V08
        // arbitrates contradictions during re-validation.
        var staleProbePlatforms: [String] = []
        for (platformKey, claim) in record.platforms.sorted(by: { $0.key < $1.key }) {
            guard claim.evidence.contains(where: { $0.kind == .buildVerdict }) else { continue }
            let verdict = input.buildVerdicts[BuildVerdict.key(canonicalURL: home, platform: platformKey)]
            if verdict == nil || verdict!.commit != input.newCommit || verdict!.outcome == .inconclusive {
                staleProbePlatforms.append(platformKey)
            }
        }
        if !staleProbePlatforms.isEmpty {
            return RecordRecheck(
                capabilityID: record.capability.id, outcome: .needsProbe,
                reason: "build verdict pinned to the old commit on \(staleProbePlatforms.joined(separator: ", ")) — run `index build-probe` at \(input.newTag) first",
                anchors: [], diagnostics: [], proposed: nil)
        }

        // 2+3 — anchor repair ladder + presence comparison, per claim.
        var findings: [AnchorFinding] = []
        var repairedDecls: [String: SurfaceDecl] = [:]  // "platform#index" → new decl
        var gone = 0
        var blockingFlips: [String] = []

        for (platformKey, claim) in record.platforms.sorted(by: { $0.key < $1.key }) {
            for (index, anchor) in claim.evidence.enumerated() {
                let resolvable = anchor.kind == .symbol || anchor.kind == .guard || anchor.kind == .availability
                guard resolvable else {
                    findings.append(finding(platformKey, index, anchor, change: .notApplicable))
                    continue
                }

                let oldDecl = try? AnchorResolver.resolve(anchor, home: home,
                                                          surfaces: input.oldSurfaces).get()
                let (change, newDecl) = repair(anchor, home: home, in: input.newSurfaces)

                guard let newDecl else {
                    gone += 1
                    findings.append(finding(platformKey, index, anchor, change: change,
                                            oldDecl: oldDecl,
                                            detail: goneDetail(anchor, change: change)))
                    continue
                }
                if change != .unchanged {
                    repairedDecls["\(platformKey)#\(index)"] = newDecl
                }

                // Presence on THIS claim's platform, three states collapsed.
                let oldState = state(oldDecl, platformKey)
                let newState = state(newDecl, platformKey)
                let conditionMoved = oldState == newState && newState != nil
                    && oldDecl?.rawCondition != newDecl.rawCondition
                if conditionMoved {
                    repairedDecls["\(platformKey)#\(index)"] = newDecl
                }

                var detail: String?
                if oldState != newState {
                    detail = "\(anchor.symbol ?? "?") on \(platformKey): \(oldState ?? "unresolved") → \(newState ?? "unresolved") at \(input.newTag)"
                    // Unknown claims can't rot into falsehood — the flip is
                    // reported but re-validation stays the arbiter for them.
                    if claim.status != .unknown {
                        blockingFlips.append(detail!)
                    }
                } else if conditionMoved {
                    detail = "guard text changed, resolved state did not: \(newDecl.rawCondition ?? "unconditional")"
                }

                findings.append(AnchorFinding(
                    platform: platformKey, anchorIndex: index, kind: anchor.kind.rawValue,
                    symbol: anchor.symbol, change: change,
                    conditionTextUpdated: conditionMoved,
                    oldFile: anchor.file, oldLine: anchor.line,
                    newFile: newDecl.location.file, newLine: newDecl.location.line,
                    oldPresence: oldState, newPresence: newState, detail: detail))
            }
        }

        if gone > 0 {
            return RecordRecheck(
                capabilityID: record.capability.id, outcome: .anchorGone,
                reason: "\(gone) anchor\(gone == 1 ? "" : "s") no longer resolve\(gone == 1 ? "s" : "") at \(input.newTag) — relabel against the new surface",
                anchors: findings, diagnostics: [], proposed: nil)
        }
        if !blockingFlips.isEmpty {
            return RecordRecheck(
                capabilityID: record.capability.id, outcome: .truthChanged,
                reason: blockingFlips.joined(separator: "; "),
                anchors: findings, diagnostics: [], proposed: nil)
        }

        // 4 — proposal: same claims, repaired anchor locations, refreshed
        // condition text, bumped pin.
        let proposed = proposal(record, input: input, repaired: repairedDecls, findings: findings)

        // 5 — re-validation is the final arbiter: V03/V04 status
        // contradictions and V05 ceiling shifts (binary targets appearing,
        // macro attributes, all-conditional) read as truth changes.
        let result = RecordValidator.validate(proposed, surfaces: input.newSurfaces,
                                              digests: input.newDigests,
                                              buildVerdicts: input.buildVerdicts,
                                              taxonomy: input.taxonomy)
        guard result.isAccepted else {
            return RecordRecheck(
                capabilityID: record.capability.id, outcome: .truthChanged,
                reason: "the bumped record no longer validates at \(input.newTag): \(result.errors.map(\.rule).sorted().joined(separator: ", "))",
                anchors: findings, diagnostics: result.diagnostics, proposed: nil)
        }

        let repairs = findings.filter { $0.change == .lineRepaired || $0.change == .fileRepaired }.count
        return RecordRecheck(
            capabilityID: record.capability.id, outcome: .stillTrue,
            reason: repairs == 0
                ? "every anchor holds at \(input.newTag)"
                : "every anchor holds at \(input.newTag) (\(repairs) location\(repairs == 1 ? "" : "s") repaired)",
            anchors: findings, diagnostics: result.diagnostics, proposed: proposed)
    }

    // MARK: - Ladder

    /// Exact resolution first; then the repair ladder. Repair mirrors the
    /// resolver's own identity rule: a decl is "the same one" only when its
    /// qualified name pins it uniquely — in the anchor's file (line repair)
    /// or on the whole surface (file repair).
    private static func repair(_ anchor: EvidenceAnchor, home: String,
                               in surfaces: [String: PackageSurface]) -> (AnchorFinding.Change, SurfaceDecl?) {
        switch AnchorResolver.resolve(anchor, home: home, surfaces: surfaces) {
        case .success(let match):
            return (.unchanged, match)
        case .failure(.notResolvable), .failure(.noSymbol):
            return (.unresolved, nil)
        case .failure(.noSurface), .failure(.symbolMissing):
            return (.unresolved, nil)
        case .failure(.ambiguous), .failure(.fileMismatch), .failure(.lineMismatch):
            guard let symbol = anchor.symbol,
                  let surface = surfaces[anchor.package ?? home] else { return (.unresolved, nil) }
            let candidates = surface.decls.filter { $0.name == symbol }
            let inFile = candidates.filter { $0.location.file == anchor.file }
            if inFile.count == 1 { return (.lineRepaired, inFile[0]) }
            if inFile.isEmpty, candidates.count == 1 { return (.fileRepaired, candidates[0]) }
            return (.ambiguous, nil)
        }
    }

    // MARK: - Proposal

    private static func proposal(_ record: CapabilityRecord, input: Input,
                                 repaired: [String: SurfaceDecl],
                                 findings: [AnchorFinding]) -> CapabilityRecord {
        let refreshed = Set(findings.filter(\.conditionTextUpdated)
            .map { "\($0.platform)#\($0.anchorIndex)" })
        var platforms: [String: PlatformClaim] = [:]
        for (platformKey, claim) in record.platforms {
            let evidence = claim.evidence.enumerated().map { index, anchor -> EvidenceAnchor in
                let key = "\(platformKey)#\(index)"
                guard let decl = repaired[key] else { return anchor }
                return EvidenceAnchor(
                    kind: anchor.kind, symbol: anchor.symbol,
                    file: anchor.file.map { _ in decl.location.file },
                    line: anchor.line.map { _ in decl.location.line },
                    condition: refreshed.contains(key) ? decl.rawCondition : anchor.condition,
                    availability: anchor.availability, package: anchor.package,
                    note: anchor.note)
            }
            platforms[platformKey] = PlatformClaim(status: claim.status,
                                                   confidence: claim.confidence,
                                                   evidence: evidence)
        }
        let package = RecordPackage(
            canonicalURL: record.package.canonicalURL, name: record.package.name,
            aliases: record.package.aliases, version: input.newTag,
            commit: input.newCommit,
            surfaceDigest: input.newDigests[record.package.canonicalURL]
                ?? record.package.surfaceDigest,
            firstParty: record.package.firstParty)
        return CapabilityRecord(recordVersion: record.recordVersion, package: package,
                                capability: record.capability, platforms: platforms,
                                requiresCompanion: record.requiresCompanion,
                                notes: record.notes, labeledBy: record.labeledBy,
                                labeledAt: record.labeledAt)
    }

    // MARK: - Small helpers

    private static func state(_ decl: SurfaceDecl?, _ platform: String) -> String? {
        switch decl?.resolvedPlatforms?[platform] {
        case .present: "present"
        case .absent: "absent"
        case .conditional: "conditional"
        case nil: nil
        }
    }

    private static func finding(_ platform: String, _ index: Int, _ anchor: EvidenceAnchor,
                                change: AnchorFinding.Change, oldDecl: SurfaceDecl? = nil,
                                detail: String? = nil) -> AnchorFinding {
        AnchorFinding(platform: platform, anchorIndex: index, kind: anchor.kind.rawValue,
                      symbol: anchor.symbol, change: change, conditionTextUpdated: false,
                      oldFile: anchor.file, oldLine: anchor.line,
                      newFile: nil, newLine: nil,
                      oldPresence: state(oldDecl, platform), newPresence: nil, detail: detail)
    }

    private static func goneDetail(_ anchor: EvidenceAnchor, change: AnchorFinding.Change) -> String {
        switch change {
        case .ambiguous:
            "‘\(anchor.symbol ?? "?")’ now has multiple declarations and none is identifiable as this anchor"
        default:
            "‘\(anchor.symbol ?? "?")’ no longer exists on the surface"
        }
    }
}
