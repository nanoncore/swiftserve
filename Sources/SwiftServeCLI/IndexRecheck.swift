import ArgumentParser
import Foundation
import SwiftServeCapability
import SwiftServeCore
import SwiftServeSurface

// MARK: - recheck

/// `swiftserve index recheck` — the self-checking index. Polls every indexed
/// package for tags newer than its records' pin, re-extracts at the new tag,
/// and diffs each record's anchors against the fresh surface. Report-only by
/// default and side-effect free; `--apply` lands still-true bumps. Records
/// whose truth changed are never auto-written — they're the finding.
struct Recheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-verify records against the latest stable upstream tags; --apply bumps still-true pins."
    )

    @Option(name: .long, help: "Root of accepted records (domain subdirs are scanned).")
    var records: String = "data/records"

    @Option(name: .long, help: "Recheck only this package (owner/repo or URL fragment).")
    var package: String?

    @Option(name: .long, help: "Recheck against this tag instead of the latest stable (requires --package).")
    var tag: String?

    @Option(name: .long, help: "Lockfile written by `index fetch`.")
    var lock: String = CorpusFiles.defaultLock

    @Option(name: .long, help: "Build-verdict artifacts records may cite.")
    var buildVerdicts: String = "data/build-verdicts"

    @Option(name: .long, help: "Directory of per-domain taxonomy files (merged).")
    var taxonomyDir: String = "data/taxonomy"

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    @Flag(name: .long, help: "Write still-true bumps to records, lockfile, and cache. Truth-changed and anchor-gone are never written.")
    var apply = false

    @Flag(name: .long, help: "Print the machine-readable recheck report JSON instead of the card.")
    var json = false

    @Option(name: .long, help: "Write the report JSON to this file (the card still prints).")
    var out: String?

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        let taxonomy = try Assemble.mergedTaxonomy(taxonomyDir)
        var lockFile = (try? CorpusFiles.read(lock, as: CorpusLock.decode)) ?? CorpusLock()
        let verdicts = Self.loadBuildVerdicts(buildVerdicts)

        // Group records by package, keeping file paths for the apply pass —
        // one package's records can span domain files.
        let recordFiles = try Validate.recordFilesByPath(records)
        var byPackage: [String: [(file: URL, record: CapabilityRecord)]] = [:]
        for (file, fileRecords) in recordFiles {
            for record in fileRecords {
                byPackage[record.package.canonicalURL, default: []].append((file, record))
            }
        }
        if let package {
            byPackage = byPackage.filter { $0.key.localizedCaseInsensitiveContains(package) }
            guard !byPackage.isEmpty else { throw ScanError("no record package matches ‘\(package)’") }
        }
        if tag != nil, byPackage.count != 1 {
            throw ScanError("--tag pins one package — use --package to select exactly one (matched \(byPackage.count))")
        }

        var entries: [RecheckReport.PackageEntry] = []
        var lockDirty = false

        for url in byPackage.keys.sorted() {
            let items = byPackage[url]!
            let name = items[0].record.package.name
            let files = Array(Set(items.map(\.file.relativePath))).sorted()

            // Skip gates: no tags to poll for Apple SDKs or non-GitHub homes.
            if items.contains(where: { $0.record.package.firstParty }) {
                entries.append(.init(canonicalURL: url, name: name, status: "skipped",
                                     skipReason: "first-party", recordFiles: files))
                print(Style.dim("   ~ \(name): first-party — the pin is the SDK, not a tag"))
                continue
            }
            guard RepoIdentity.ownerRepo(from: url) != nil else {
                entries.append(.init(canonicalURL: url, name: name, status: "skipped",
                                     skipReason: "non-github", recordFiles: files))
                print(Style.dim("   ~ \(name): not a GitHub package — nothing to poll"))
                continue
            }

            do {
                let entry = try recheckPackage(url: url, name: name, items: items, files: files,
                                               store: store, taxonomy: taxonomy,
                                               verdicts: verdicts, lockFile: &lockFile,
                                               lockDirty: &lockDirty)
                entries.append(entry)
            } catch let e as ScanError {
                entries.append(.init(canonicalURL: url, name: name, status: "error",
                                     errorDetail: e.message,
                                     pinnedTag: items[0].record.package.version,
                                     pinnedCommit: items[0].record.package.commit,
                                     recordFiles: files))
                print(Style.red("   ✗ \(name): \(e.message)"))
            }
        }

        if lockDirty {
            try CorpusFiles.writeJSON(lockFile, to: lock)
        }

        let report = RecheckReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            apply: apply, packages: entries)
        if let out {
            try CorpusFiles.writeJSON(report, to: out)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            printCard(report)
        }
    }

    // MARK: - One package

    private func recheckPackage(url: String, name: String,
                                items: [(file: URL, record: CapabilityRecord)],
                                files: [String], store: CorpusStore, taxonomy: Taxonomy,
                                verdicts: [String: BuildVerdict],
                                lockFile: inout CorpusLock, lockDirty: inout Bool) throws -> RecheckReport.PackageEntry {
        // Pin consistency: every record for the package must carry the same
        // pin, and the lockfile must agree — recheck bumps a coherent state
        // or refuses (the V06 invariant: record pin == lock pin == cache).
        let pins = Set(items.map { "\($0.record.package.version)@\($0.record.package.commit)" })
        guard pins.count == 1 else {
            throw ScanError("records disagree on the pin (\(pins.sorted().joined(separator: " vs "))) — refetch and revalidate before rechecking")
        }
        let pinnedTag = items[0].record.package.version
        let pinnedCommit = items[0].record.package.commit
        guard let lockEntry = lockFile.packages[url], lockEntry.commit == pinnedCommit else {
            throw ScanError("lockfile disagrees with the records’ pin \(pinnedTag) (\(pinnedCommit.prefix(8))) — run `index fetch --package \(name) --tag \(pinnedTag) --force`")
        }

        // Latest stable tag — one ls-remote, no clone yet.
        let latestTag: String
        if let tag {
            latestTag = tag
        } else {
            guard let best = SemVer.maxStableTag(try GitRunner.remoteTags(url)) else {
                print(Style.dim("   ~ \(name): no stable semver tag — nothing to compare against"))
                return .init(canonicalURL: url, name: name, status: "skipped",
                             skipReason: "no-stable-tag", pinnedTag: pinnedTag,
                             pinnedCommit: pinnedCommit, recordFiles: files)
            }
            latestTag = best
        }
        if latestTag == pinnedTag {
            print(Style.dim("   · \(name) @ \(pinnedTag) — up to date"))
            let rechecks = items.map {
                RecordRecheck(capabilityID: $0.record.capability.id, outcome: .upToDate,
                              reason: "pinned tag \(pinnedTag) is still the latest stable",
                              anchors: [], diagnostics: [], proposed: nil)
            }
            return .init(canonicalURL: url, name: name, status: "up-to-date",
                         pinnedTag: pinnedTag, pinnedCommit: pinnedCommit,
                         latestTag: latestTag, recordFiles: files, records: rechecks)
        }

        // Old baseline: the cached surface must be exactly what the records
        // were validated against — otherwise the diff would be meaningless.
        let oldSurfacePath = store.surfaceFile(for: url).path
        guard let oldBytes = FileManager.default.contents(atPath: oldSurfacePath) else {
            throw ScanError("no cached surface at the pinned tag — run `index fetch --package \(name) --tag \(pinnedTag) --force && index extract --package \(name)`")
        }
        let oldDigest = ContentDigest.fnv1a64(oldBytes)
        let oldSurface = try JSONDecoder().decode(PackageSurface.self, from: oldBytes)
        guard oldSurface.package.commit == pinnedCommit,
              items.allSatisfy({ $0.record.package.surfaceDigest == oldDigest }) else {
            throw ScanError("cached surface drifted from the records’ pin — run `index fetch --package \(name) --tag \(pinnedTag) --force && index extract --package \(name)`")
        }

        // Companion surfaces ride along unchanged (they bump in their own
        // rechecks); a missing one reads as anchor-gone, matching validate.
        var oldSurfaces: [String: PackageSurface] = [url: oldSurface]
        var newDigests: [String: String] = [:]
        var companionURLs = Set<String>()
        for (_, record) in items {
            companionURLs.formUnion(record.requiresCompanion)
            for claim in record.platforms.values {
                companionURLs.formUnion(claim.evidence.compactMap(\.package))
            }
        }
        companionURLs.remove(url)
        for companion in companionURLs {
            guard let data = FileManager.default.contents(atPath: store.surfaceFile(for: companion).path),
                  let surface = try? JSONDecoder().decode(PackageSurface.self, from: data) else { continue }
            oldSurfaces[companion] = surface
            newDigests[companion] = ContentDigest.fnv1a64(data)
        }

        // New surface: clone the new tag into a scratch dir and extract in
        // memory. Report-only runs leave the cache and lockfile untouched.
        let scratch = store.root.appendingPathComponent("recheck")
            .appendingPathComponent(CorpusStore.slug(for: url))
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var scratchKept = false
        defer { if !scratchKept { try? FileManager.default.removeItem(at: scratch) } }

        try GitRunner.run(["clone", "--quiet", "--depth", "1", "--branch", latestTag, url, scratch.path])
        let latestCommit = try GitRunner.run(["rev-parse", "HEAD"], cwd: scratch.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newSurface = try SurfaceBuilder.build(
            path: scratch.path,
            provenance: PackageProvenance(
                canonicalURL: url,
                name: RepoIdentity.ownerRepo(from: url)?.repo ?? name,
                tag: latestTag, commit: latestCommit),
            modules: try Surface.loadModuleTable())
        let newJSON = try SurfaceBuilder.encodeJSON(newSurface) + "\n"
        var newSurfaces = oldSurfaces
        newSurfaces[url] = newSurface
        newDigests[url] = ContentDigest.fnv1a64(Data(newJSON.utf8))

        // The pure engine buckets each record.
        let rechecks = items.map { _, record in
            RecheckEngine.recheck(.init(record: record, oldSurfaces: oldSurfaces,
                                        newSurfaces: newSurfaces, newDigests: newDigests,
                                        newTag: latestTag, newCommit: latestCommit,
                                        buildVerdicts: verdicts, taxonomy: taxonomy))
        }
        let heldBackBy = rechecks.filter { $0.outcome != .stillTrue }.map(\.capabilityID).sorted()

        // Apply, package-level all-or-nothing: a partial bump would break the
        // held-back records' V06 provenance, so any non-still-true holds the
        // whole package back.
        var applied = false
        if apply, heldBackBy.isEmpty {
            let proposals = Dictionary(uniqueKeysWithValues: rechecks.map { ($0.capabilityID, $0.proposed!) })
            for file in Set(items.map(\.file)) {
                guard let data = FileManager.default.contents(atPath: file.path) else { continue }
                let rewritten = try Validate.decodeRecords(data).map { record -> CapabilityRecord in
                    guard record.package.canonicalURL == url,
                          let proposal = proposals[record.capability.id] else { return record }
                    return proposal
                }
                try CorpusFiles.writeJSON(rewritten, to: file.path)
            }
            lockFile.packages[url] = CorpusLock.Entry(
                tag: latestTag, commit: latestCommit,
                fetchedAt: ISO8601DateFormatter().string(from: Date()))
            lockDirty = true
            let checkout = store.checkoutDir(for: url)
            if FileManager.default.fileExists(atPath: checkout.path) {
                try FileManager.default.removeItem(at: checkout)
            }
            try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: scratch, to: checkout)
            scratchKept = true
            try FileManager.default.createDirectory(at: store.surfaces, withIntermediateDirectories: true)
            try Data(newJSON.utf8).write(to: store.surfaceFile(for: url))
            applied = true
        }

        for recheck in rechecks {
            switch recheck.outcome {
            case .stillTrue:
                print(Style.green("   ✓ \(name) × \(recheck.capabilityID)") + " — \(recheck.reason)"
                      + (applied ? " (applied)" : ""))
            case .truthChanged:
                print(Style.yellow("   ~ \(name) × \(recheck.capabilityID) — TRUTH CHANGED: \(recheck.reason)"))
            case .anchorGone:
                print(Style.yellow("   ~ \(name) × \(recheck.capabilityID) — \(recheck.reason)"))
            case .needsProbe:
                print(Style.dim("   ~ \(name) × \(recheck.capabilityID) — \(recheck.reason)"))
            default:
                break
            }
        }

        return .init(canonicalURL: url, name: name, status: "new-tag",
                     pinnedTag: pinnedTag, pinnedCommit: pinnedCommit,
                     latestTag: latestTag, latestCommit: latestCommit,
                     applied: applied, heldBackBy: applied ? [] : heldBackBy,
                     recordFiles: files, records: rechecks)
    }

    // MARK: - Output

    private func printCard(_ report: RecheckReport) {
        let s = report.summary
        let parts = [
            s.upToDate > 0 ? "\(s.upToDate) up-to-date" : nil,
            s.stillTrue > 0 ? "\(s.stillTrue) still true" : nil,
            s.truthChanged > 0 ? "\(s.truthChanged) truth changed" : nil,
            s.anchorGone > 0 ? "\(s.anchorGone) anchors gone" : nil,
            s.needsProbe > 0 ? "\(s.needsProbe) need a probe" : nil,
            s.skipped > 0 ? "\(s.skipped) skipped" : nil,
            s.errors > 0 ? "\(s.errors) errors" : nil,
        ].compactMap { $0 }
        let count = report.packages.count
        print(Style.bold("🍦 recheck complete") + " — \(count) package\(count == 1 ? "" : "s"): "
              + (parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")))
        if s.stillTrue > 0, !report.apply {
            print(Style.dim("   \(s.stillTrue) record\(s.stillTrue == 1 ? "" : "s") ready to bump — re-run with --apply"))
        }
        if report.summary.applied > 0 {
            print(Style.dim("   \(s.applied) package\(s.applied == 1 ? "" : "s") bumped — run `swiftserve index assemble` and `make site` to ship"))
        }
        if s.truthChanged > 0 || s.anchorGone > 0 {
            print(Style.dim("   truth-changed / anchor-gone records need a human: relabel against the new surface"))
        }
        if s.needsProbe > 0 {
            print(Style.dim("   needs-probe records want `index build-probe` at the new tag first"))
        }
    }

    static func loadBuildVerdicts(_ dir: String) -> [String: BuildVerdict] {
        var verdicts: [String: BuildVerdict] = [:]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let verdict = try? BuildVerdict.decode(from: data) else { continue }
            verdicts[verdict.key] = verdict
        }
        return verdicts
    }
}
