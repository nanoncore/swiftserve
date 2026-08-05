import Foundation
import SwiftServeCapability
import SwiftServeCore
import SwiftServeReceipt

enum CapabilityReceiptRechecker {
    struct Result {
        let impacts: [String: [CapabilityImpact]]
        let executed: Bool
        let networkUsed: Bool
        let unavailable: [String]
    }

    static func recheck(base: [Pin], head: [Pin], dataset: CapabilityDataset) -> Result {
        let changed = Diff.changedRepositoryPins(base: base, head: head)
        let baseByID = Dictionary(grouping: base, by: { RepoIdentity.normalizedPackageIdentity($0.identity) })
        let headByID = Dictionary(grouping: head, by: { RepoIdentity.normalizedPackageIdentity($0.identity) })
        var impacts: [String: [CapabilityImpact]] = [:]
        var unavailable: [String] = []
        var executed = false
        var networkUsed = false

        for representative in changed {
            let identity = RepoIdentity.normalizedPackageIdentity(representative.identity)
            let old = baseByID[identity]?.first
            guard let new = headByID[identity]?.first else { continue }
            let canonical = RepoIdentity.canonicalURL(new.location)
            let records = dataset.records.filter {
                $0.package.canonicalURL == canonical
                    || $0.package.name.lowercased() == identity
                    || $0.package.aliases.contains { $0.lowercased() == identity }
            }
            guard !records.isEmpty else { continue }
            if records.contains(where: { $0.package.firstParty }) {
                impacts[identity] = [.init(
                    capability: nil, platform: nil, outcome: .firstPartySkipped,
                    baseStatus: nil, headStatus: nil, evidenceVersion: nil,
                    detail: "First-party SDK records were skipped; their pin is an SDK, not a dependency release.")]
                continue
            }
            // Already-current records are stronger than a redundant network
            // pass: keep their exact verified evidence, including build probes.
            if records.allSatisfy({ pin(new, matches: $0) }) { continue }
            guard new.pinType == .version,
                  let headVersion = new.resolvedVersion,
                  RepoIdentity.ownerRepo(from: canonical) != nil else {
                impacts[identity] = unavailableImpacts(records, detail: "Capability recheck requires a GitHub semantic-version head pin.")
                unavailable.append(identity)
                continue
            }

            networkUsed = true
            do {
                let checked = try recheckPackage(canonicalURL: canonical, basePin: old, headVersion: headVersion,
                                                 records: records, dataset: dataset)
                impacts[identity] = checked
                executed = true
            } catch {
                impacts[identity] = unavailableImpacts(
                    records, detail: "Capability recheck was unavailable: \(sanitized(error)).")
                unavailable.append(identity)
            }
        }
        return Result(impacts: impacts, executed: executed, networkUsed: networkUsed,
                      unavailable: unavailable.sorted())
    }

    private static func recheckPackage(canonicalURL: String, basePin: Pin?, headVersion: String,
                                       records: [CapabilityRecord], dataset: CapabilityDataset) throws -> [CapabilityImpact] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftserve-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modules = try Surface.loadModuleTable()
        var oldSurfaces: [String: PackageSurface] = [:]
        var newSurfaces: [String: PackageSurface] = [:]
        var newDigests: [String: String] = [:]

        let recordVersion = records[0].package.version
        let oldSurface = try checkoutSurface(url: canonicalURL, tag: recordVersion,
                                             directory: root.appendingPathComponent("old"), modules: modules)
        let newSurface = try checkoutSurface(url: canonicalURL, tag: headVersion,
                                             directory: root.appendingPathComponent("head"), modules: modules)
        oldSurfaces[canonicalURL] = oldSurface.surface
        newSurfaces[canonicalURL] = newSurface.surface
        newDigests[canonicalURL] = newSurface.digest

        let companions = Set(records.flatMap { record in
            record.requiresCompanion + record.platforms.values.flatMap { $0.evidence.compactMap(\.package) }
        }).subtracting([canonicalURL])
        for (offset, companion) in companions.sorted().enumerated() {
            guard let companionRecord = dataset.records.first(where: { $0.package.canonicalURL == companion }),
                  !companionRecord.package.firstParty else { continue }
            let checked = try checkoutSurface(
                url: companion, tag: companionRecord.package.version,
                directory: root.appendingPathComponent("companion-\(offset)"), modules: modules)
            oldSurfaces[companion] = checked.surface
            newSurfaces[companion] = checked.surface
            newDigests[companion] = checked.digest
        }

        return records.sorted { $0.capability.id < $1.capability.id }.flatMap { record in
            let result = RecheckEngine.recheck(.init(
                record: record, oldSurfaces: oldSurfaces, newSurfaces: newSurfaces,
                newDigests: newDigests, newTag: headVersion, newCommit: newSurface.commit,
                taxonomy: dataset.taxonomy))
            return impacts(record: record, recheck: result, basePin: basePin,
                           headVersion: headVersion, dataset: dataset)
        }
    }

    private struct CheckedSurface {
        let surface: PackageSurface
        let digest: String
        let commit: String
    }

    private static func checkoutSurface(url: String, tag: String, directory: URL,
                                        modules: ModulePlatformTable) throws -> CheckedSurface {
        do {
            try GitRunner.run(["clone", "--quiet", "--depth", "1", "--branch", tag, url, directory.path])
        } catch {
            guard !tag.hasPrefix("v") else { throw error }
            try GitRunner.run(["clone", "--quiet", "--depth", "1", "--branch", "v\(tag)", url, directory.path])
        }
        let commit = try GitRunner.run(["rev-parse", "HEAD"], cwd: directory.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = try SurfaceBuilder.build(
            path: directory.path,
            provenance: PackageProvenance(
                canonicalURL: url, name: RepoIdentity.ownerRepo(from: url)?.repo ?? url,
                tag: tag, commit: commit), modules: modules)
        let encoded = try SurfaceBuilder.encodeJSON(surface) + "\n"
        return CheckedSurface(surface: surface, digest: ContentDigest.fnv1a64(Data(encoded.utf8)), commit: commit)
    }

    private static func impacts(record: CapabilityRecord, recheck: RecordRecheck,
                                basePin: Pin?, headVersion: String, dataset: CapabilityDataset) -> [CapabilityImpact] {
        let outcome: CapabilityImpactOutcome = switch recheck.outcome {
        case .stillTrue: .stillTrue
        case .truthChanged: .truthChanged
        case .anchorGone: .anchorGone
        case .needsProbe: .needsProbe
        default: .unavailable
        }
        let proposed = recheck.proposed
        return record.platforms.keys.sorted().map { platform in
            let oldClaim = record.platforms[platform]!
            let headClaim = proposed?.platforms[platform]
            let evidence = (headClaim ?? oldClaim).evidence.map { anchor in
                let target = anchor.package ?? record.package.canonicalURL
                let permalink: String?
                if let file = anchor.file, let line = anchor.line,
                   RepoIdentity.ownerRepo(from: target) != nil {
                    let tag = target == record.package.canonicalURL
                        ? (headClaim == nil ? record.package.version : headVersion)
                        : (dataset.records.first { $0.package.canonicalURL == target }?.package.version
                           ?? record.package.version)
                    permalink = "\(target)/blob/\(tag)/\(file)#L\(line)"
                } else { permalink = nil }
                return ReceiptEvidence(kind: anchor.kind.rawValue, symbol: anchor.symbol,
                                       file: anchor.file, line: anchor.line,
                                       condition: anchor.condition, permalink: permalink)
            }
            return CapabilityImpact(
                capability: record.capability.id, platform: platform, outcome: outcome,
                baseStatus: basePin.map { pin($0, matches: record) } == true ? oldClaim.status : nil,
                headStatus: headClaim?.status,
                evidenceVersion: headClaim == nil ? record.package.version : headVersion,
                detail: recheck.reason, evidence: evidence)
        }
    }

    private static func pin(_ pin: Pin, matches record: CapabilityRecord) -> Bool {
        guard let version = pin.resolvedVersion else { return false }
        let sameVersion = version == record.package.version
            || (SemVer(version) != nil && SemVer(version) == SemVer(record.package.version))
        guard sameVersion else { return false }
        guard let revision = pin.revision, !revision.isEmpty else { return true }
        return revision.caseInsensitiveCompare(record.package.commit) == .orderedSame
    }

    private static func unavailableImpacts(_ records: [CapabilityRecord], detail: String) -> [CapabilityImpact] {
        records.sorted { $0.capability.id < $1.capability.id }.flatMap { record in
            record.platforms.keys.sorted().map { platform in
                CapabilityImpact(
                    capability: record.capability.id, platform: platform, outcome: .unavailable,
                    baseStatus: nil, headStatus: nil, evidenceVersion: nil, detail: detail)
            }
        }
    }

    private static func sanitized(_ error: Error) -> String {
        let message = (error as? ScanError)?.message ?? error.localizedDescription
        // Git commands may include remote diagnostics. Keep the receipt useful
        // without echoing credential-bearing URLs or fetched contents.
        if message.contains("git clone") { return "source checkout failed" }
        return message.replacingOccurrences(of: "\n", with: " ")
    }
}
