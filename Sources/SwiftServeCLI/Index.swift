import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftServeCapability
import SwiftServeCore

/// `swiftserve index` — the founder-facing corpus pipeline: discover a
/// domain's packages, fetch them at pinned tags, extract their surfaces.
/// All the impure work (network, git, disk) lives here; everything it
/// produces is plain JSON the pure layers consume.
struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build the capability corpus: discover, fetch, extract, label, validate.",
        subcommands: [Discover.self, Fetch.self, Extract.self, LabelPrep.self, Validate.self, Assemble.self]
    )
}

// MARK: - Shared plumbing

/// Where checkouts and extracted surfaces live. Cache, not repo: surfaces
/// rebuild byte-identical from the lockfile, so only small versioned truth
/// (seeds, corpus, lock, records) belongs in `data/`.
struct CorpusStore {
    let root: URL

    init(override: String?) {
        if let override {
            root = URL(fileURLWithPath: override).standardizedFileURL
        } else if let env = ProcessInfo.processInfo.environment["SWIFTSERVE_CORPUS"], !env.isEmpty {
            root = URL(fileURLWithPath: env).standardizedFileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            root = caches.appendingPathComponent("swiftserve/corpus")
        }
    }

    var checkouts: URL { root.appendingPathComponent("checkouts") }
    var surfaces: URL { root.appendingPathComponent("surface") }
    var labeling: URL { root.appendingPathComponent("labeling") }

    /// `livekit__client-sdk-swift` — the canonical directory slug.
    static func slug(for canonicalURL: String) -> String {
        if let (owner, repo) = RepoIdentity.ownerRepo(from: canonicalURL) {
            return "\(owner.lowercased())__\(repo.lowercased())"
        }
        return canonicalURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "/", with: "__")
            .lowercased()
    }

    func checkoutDir(for canonicalURL: String) -> URL {
        checkouts.appendingPathComponent(Self.slug(for: canonicalURL))
    }

    func surfaceFile(for canonicalURL: String) -> URL {
        surfaces.appendingPathComponent(Self.slug(for: canonicalURL) + ".json")
    }
}

/// Thin `Process` wrapper around the git binary — shell out, don't link.
/// (Precedent: the Build pillar drives `swift build` the same way.)
enum GitRunner {
    @discardableResult
    static func run(_ arguments: [String], cwd: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScanError("git \(arguments.first ?? "") failed: \(message.isEmpty ? "exit \(process.terminationStatus)" : message)")
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// Tag names from `ls-remote --tags`, annotated-tag `^{}` entries collapsed.
    static func remoteTags(_ url: String) throws -> [String] {
        let output = try run(["ls-remote", "--tags", url])
        var tags: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { continue }
            var tag = String(ref.dropFirst("refs/tags/".count))
            if tag.hasSuffix("^{}") { tag = String(tag.dropLast(3)) }
            tags.insert(tag)
        }
        return Array(tags).sorted()
    }
}

enum CorpusFiles {
    static let defaultSeed = "data/corpus/seed.audio.json"
    static let defaultCorpus = "data/corpus/corpus.audio.json"
    static let defaultLock = "data/corpus/corpus.lock.json"

    static func read<T>(_ path: String, as decode: (Data) throws -> T) throws -> T {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ScanError("couldn't read \(path)")
        }
        return try decode(data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(try encoder.encode(value) + Data("\n".utf8)).write(to: url)
    }
}

// MARK: - discover

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sweep the SwiftPackageIndex package list for a domain's candidate packages."
    )

    @Option(name: .long, help: "Domain seed file (keywords + hand-curated packages).")
    var seed: String = CorpusFiles.defaultSeed

    @Option(name: .long, help: "Where to write the corpus JSON (hand-prune it afterwards).")
    var out: String = CorpusFiles.defaultCorpus

    @Option(name: .long, help: "Package-list URL (SwiftPackageIndex master list).")
    var packageList = "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json"

    func run() async throws {
        let seedFile = try CorpusFiles.read(seed, as: CorpusSeed.decode)

        guard let listURL = URL(string: packageList) else { throw ScanError("bad package-list URL") }
        let (data, _) = try await URLSession.shared.data(from: listURL)
        let allURLs = try JSONDecoder().decode([String].self, from: data)

        let seedCandidates = seedFile.packages.map { pkg in
            DomainCandidate(url: RepoIdentity.canonicalURL(pkg.url),
                            name: candidateName(pkg.url),
                            source: "seed", why: pkg.why, companionOf: pkg.companionOf.map(RepoIdentity.canonicalURL))
        }
        let seedURLs = Set(seedCandidates.map(\.url))

        let keywordCandidates = DomainFilter.match(urls: allURLs, keywords: seedFile.keywords)
            .map { DomainCandidate(url: RepoIdentity.canonicalURL($0), name: candidateName($0), source: "keyword") }
            .filter { !seedURLs.contains($0.url) }
            .reduce(into: [DomainCandidate]()) { acc, candidate in   // dedupe, keep order stable
                if !acc.contains(where: { $0.url == candidate.url }) { acc.append(candidate) }
            }
            .sorted { $0.url < $1.url }

        let corpus = Corpus(domain: seedFile.domain, packages: seedCandidates + keywordCandidates)
        try CorpusFiles.writeJSON(corpus, to: out)

        print(Style.bold("🍦 \(seedFile.domain) corpus discovered"))
        print("   \(seedCandidates.count) seeds + \(keywordCandidates.count) keyword candidates (of \(allURLs.count) packages swept)")
        print(Style.dim("   → \(out) — prune the keyword hits by hand, then `swiftserve index fetch`"))
    }

    private func candidateName(_ url: String) -> String {
        if let (owner, repo) = RepoIdentity.ownerRepo(from: url) { return "\(owner)/\(repo)" }
        return URL(string: url)?.lastPathComponent ?? url
    }
}

// MARK: - fetch

struct Fetch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shallow-clone corpus packages at their latest stable tag; pin them in the lockfile."
    )

    @Option(name: .long, help: "Corpus JSON produced by `index discover`.")
    var corpus: String = CorpusFiles.defaultCorpus

    @Option(name: .long, help: "Lockfile recording tag + commit per package.")
    var lock: String = CorpusFiles.defaultLock

    @Option(name: .long, help: "Fetch only this package (owner/repo or URL fragment).")
    var package: String?

    @Option(name: .long, help: "Pin a specific tag instead of the latest stable.")
    var tag: String?

    @Flag(name: .long, help: "Re-clone even if a checkout already exists.")
    var force = false

    @Flag(name: .long, help: "Fetch only seed-sourced packages (skip unpruned keyword hits).")
    var seedsOnly = false

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        let corpusFile = try CorpusFiles.read(corpus, as: Corpus.decode)
        var lockFile = (try? CorpusFiles.read(lock, as: CorpusLock.decode)) ?? CorpusLock()

        var targets = corpusFile.packages
        if seedsOnly { targets = targets.filter { $0.source == "seed" } }
        if let package {
            targets = targets.filter { $0.url.localizedCaseInsensitiveContains(package) }
            guard !targets.isEmpty else { throw ScanError("no corpus package matches ‘\(package)’") }
        }

        try FileManager.default.createDirectory(at: store.checkouts, withIntermediateDirectories: true)
        var fetched = 0, skipped = 0, failed = 0

        for candidate in targets {
            let dir = store.checkoutDir(for: candidate.url)
            if FileManager.default.fileExists(atPath: dir.path), !force {
                skipped += 1
                continue
            }
            do {
                let pickedTag: String
                if let tag {
                    pickedTag = tag
                } else {
                    let tags = try GitRunner.remoteTags(candidate.url)
                    guard let best = SemVer.maxStableTag(tags) else {
                        print(Style.dim("   ~ \(candidate.name): no stable semver tag — skipped (use --tag to pin one)"))
                        failed += 1
                        continue
                    }
                    pickedTag = best
                }
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
                try GitRunner.run(["clone", "--quiet", "--depth", "1", "--branch", pickedTag,
                                   candidate.url, dir.path])
                let commit = try GitRunner.run(["rev-parse", "HEAD"], cwd: dir.path)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lockFile.packages[candidate.url] = CorpusLock.Entry(
                    tag: pickedTag, commit: commit,
                    fetchedAt: ISO8601DateFormatter().string(from: Date()))
                fetched += 1
                print("   ✓ \(candidate.name) @ \(pickedTag) (\(commit.prefix(8)))")
            } catch let e as ScanError {
                failed += 1
                print(Style.dim("   ✗ \(candidate.name): \(e.message)"))
            }
        }

        try CorpusFiles.writeJSON(lockFile, to: lock)
        print(Style.bold("🍦 fetch complete") + " — \(fetched) fetched, \(skipped) already present, \(failed) failed")
        print(Style.dim("   checkouts: \(store.checkouts.path)"))
    }
}

// MARK: - extract

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract resolved public surfaces for every fetched corpus package."
    )

    @Option(name: .long, help: "Corpus JSON produced by `index discover`.")
    var corpus: String = CorpusFiles.defaultCorpus

    @Option(name: .long, help: "Lockfile written by `index fetch`.")
    var lock: String = CorpusFiles.defaultLock

    @Option(name: .long, help: "Extract only this package (owner/repo or URL fragment).")
    var package: String?

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        let corpusFile = try CorpusFiles.read(corpus, as: Corpus.decode)
        let lockFile = try CorpusFiles.read(lock, as: CorpusLock.decode)
        let modules = try Surface.loadModuleTable()

        var targets = corpusFile.packages.filter { lockFile.packages[$0.url] != nil }
        if let package {
            targets = targets.filter { $0.url.localizedCaseInsensitiveContains(package) }
            guard !targets.isEmpty else { throw ScanError("no fetched corpus package matches ‘\(package)’") }
        }

        try FileManager.default.createDirectory(at: store.surfaces, withIntermediateDirectories: true)
        var extracted = 0

        for candidate in targets {
            guard let entry = lockFile.packages[candidate.url] else { continue }
            let dir = store.checkoutDir(for: candidate.url)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                print(Style.dim("   ~ \(candidate.name): checkout missing — run `index fetch` first"))
                continue
            }
            let surface = try SurfaceBuilder.build(
                path: dir.path,
                provenance: PackageProvenance(
                    canonicalURL: candidate.url,
                    name: RepoIdentity.ownerRepo(from: candidate.url)?.repo ?? candidate.name,
                    tag: entry.tag, commit: entry.commit),
                modules: modules)
            let out = store.surfaceFile(for: candidate.url)
            try Data((try SurfaceBuilder.encodeJSON(surface) + "\n").utf8).write(to: out)
            extracted += 1
            let guarded = surface.decls.filter { $0.condition != nil }.count
            print("   ✓ \(candidate.name) @ \(entry.tag): \(surface.stats.declCount) decls, \(guarded) guarded"
                  + (surface.stats.objcFiles > 0 ? Style.dim("  (\(surface.stats.objcFiles) ObjC files unparsed)") : ""))
        }

        print(Style.bold("🍦 extract complete") + " — \(extracted) surfaces → \(store.surfaces.path)")
    }
}

// MARK: - label-prep

struct LabelPrep: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label-prep",
        abstract: "Emit self-contained labeling bundles (task + surface digest) for extracted packages."
    )

    @Option(name: .long, help: "Prep only this package (owner/repo or URL fragment).")
    var package: String?

    @Option(name: .long, help: "Domain taxonomy the labels must draw from.")
    var taxonomy: String = "data/taxonomy/audio.json"

    @Option(name: .long, help: "Corpus JSON produced by `index discover`.")
    var corpus: String = CorpusFiles.defaultCorpus

    @Option(name: .long, help: "Max decls in the digest (validation always runs on the full surface).")
    var limit: Int = 800

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        let corpusFile = try CorpusFiles.read(corpus, as: Corpus.decode)
        let taxonomyData = try CorpusFiles.read(taxonomy) { $0 }
        let taxonomyFile = try Taxonomy.decode(from: taxonomyData)

        var targets = corpusFile.packages.filter {
            FileManager.default.fileExists(atPath: store.surfaceFile(for: $0.url).path)
        }
        if let package {
            targets = targets.filter { $0.url.localizedCaseInsensitiveContains(package) }
            guard !targets.isEmpty else { throw ScanError("no extracted corpus package matches ‘\(package)’") }
        }

        var prepared = 0
        for candidate in targets {
            let surfaceURL = store.surfaceFile(for: candidate.url)
            guard let surfaceData = FileManager.default.contents(atPath: surfaceURL.path) else { continue }
            let surface = try JSONDecoder().decode(PackageSurface.self, from: surfaceData)
            let digest = SurfaceDigest.build(from: surface, limit: limit)
            let surfaceDigest = ContentDigest.fnv1a64(surfaceData)

            let bundle = store.labeling.appendingPathComponent(CorpusStore.slug(for: candidate.url))
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("proposed"),
                                                    withIntermediateDirectories: true)
            try CorpusFiles.writeJSON(digest, to: bundle.appendingPathComponent("surface-digest.json").path)

            let readme = readmeExcerpt(for: candidate, store: store)
            let companions = corpusFile.packages.filter { $0.companionOf == candidate.url }.map(\.url)
            let task = taskMarkdown(candidate: candidate, surface: surface, surfaceDigest: surfaceDigest,
                                    taxonomyJSON: String(decoding: taxonomyData, as: UTF8.self),
                                    taxonomyDomain: taxonomyFile.domain,
                                    companions: companions, readme: readme)
            try Data(task.utf8).write(to: bundle.appendingPathComponent("task.md"))
            prepared += 1
            print("   ✓ \(candidate.name) → \(bundle.path)")
        }
        print(Style.bold("🍦 label-prep complete") + " — \(prepared) bundle\(prepared == 1 ? "" : "s"); write records into <bundle>/proposed/, then `swiftserve index validate --promote`")
    }

    private func readmeExcerpt(for candidate: DomainCandidate, store: CorpusStore) -> String? {
        let dir = store.checkoutDir(for: candidate.url)
        for name in ["README.md", "README.MD", "Readme.md", "readme.md"] {
            if let text = try? String(contentsOfFile: dir.appendingPathComponent(name).path, encoding: .utf8) {
                return text.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(150).joined(separator: "\n")
            }
        }
        return nil
    }

    private func taskMarkdown(candidate: DomainCandidate, surface: PackageSurface, surfaceDigest: String,
                              taxonomyJSON: String, taxonomyDomain: String,
                              companions: [String], readme: String?) -> String {
        let stats = surface.stats
        var blindSpots: [String] = []
        if stats.hasBinaryTargets { blindSpots.append("ships `.binaryTarget`s — the real fence may live in a binary (confidence cap 0.8)") }
        if stats.objcFiles > 0 { blindSpots.append("\(stats.objcFiles) ObjC files unparsed (Swift-only extraction)") }
        if stats.manifestUnparsed { blindSpots.append("Package.swift could not be read syntactically") }

        return """
        # Labeling task: \(candidate.name)

        Package: \(candidate.url)
        Version: \(surface.package.tag ?? "?") @ \(surface.package.commit ?? "?")
        Surface digest: `\(surfaceDigest)`  ← copy into every record's `package.surfaceDigest`
        \(companions.isEmpty ? "" : "Companions with their own surfaces you may cite via an anchor's `package` field: \(companions.joined(separator: ", "))\n")\(blindSpots.isEmpty ? "" : "Blind spots (be humble accordingly): " + blindSpots.joined(separator: "; ") + "\n")
        ## The contract

        Propose `CapabilityRecord` JSON files in `proposed/` — one file per capability,
        named `<capability-id>.json`. The validator is the only gate; it will reject:

        - any capability id not in the taxonomy below (V01 — propose taxonomy additions separately)
        - any symbol/guard/availability anchor whose `symbol` is not an EXACT qualified
          name from `surface-digest.json`, with exact `file` and `line` (V02)
        - `supported` without a symbol anchor the surface resolves PRESENT on that platform (V03)
        - `unsupported` without a guard/availability anchor resolving ABSENT there (V04) —
          symbol absence and manifest platforms are NEVER evidence of absence; say `unknown`
        - confidence above the caps: 0.95 absolute, 0.6 all-conditional evidence,
          0.3 readme/manifest-only (status must then be `unknown`), 0.7 macro-flagged decls,
          0.8 when binary targets are in play (V05)
        - stale provenance: `commit`/`surfaceDigest` must match this bundle (V06)

        Claim every platform (iOS, macOS, watchOS, tvOS, visionOS, macCatalyst, linux);
        `unknown` with low confidence is an honest, welcome answer. Prefer under-claiming.

        ## Record shape

        ```json
        {
          "recordVersion": 1,
          "package": {
            "canonicalURL": "\(candidate.url)",
            "name": "\(surface.package.name)",
            "aliases": [],
            "version": "\(surface.package.tag ?? "")",
            "commit": "\(surface.package.commit ?? "")",
            "surfaceDigest": "\(surfaceDigest)"
          },
          "capability": {"id": "<taxonomy id>", "label": "<taxonomy label>"},
          "platforms": {
            "iOS": {"status": "supported", "confidence": 0.9,
                    "evidence": [{"kind": "symbol", "symbol": "<Qualified.name>",
                                  "file": "<repo-relative path>", "line": 0,
                                  "condition": null, "availability": null,
                                  "package": null, "note": null}]}
          },
          "requiresCompanion": [],
          "notes": null,
          "labeledBy": "claude-code-session",
          "labeledAt": "<ISO8601 now>"
        }
        ```

        ## Taxonomy (\(taxonomyDomain))

        ```json
        \(taxonomyJSON)
        ```
        \(readme.map { "\n## README excerpt (weak evidence only — kind `readme`, confidence ≤ 0.3)\n\n\($0)\n" } ?? "")
        """
    }
}

// MARK: - validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate proposed capability records against surfaces; --promote accepted ones into data/records/."
    )

    @Option(name: .long, help: "A proposed record file or directory (default: every labeling bundle's proposed/).")
    var proposed: String?

    @Option(name: .long, help: "Domain taxonomy records must draw from.")
    var taxonomy: String = "data/taxonomy/audio.json"

    @Option(name: .long, help: "Where accepted records live, one file per package.")
    var recordsDir: String = "data/records/audio"

    @Flag(name: .long, help: "Move accepted records into the records dir.")
    var promote = false

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        let taxonomyFile = try CorpusFiles.read(taxonomy) { try Taxonomy.decode(from: $0) }

        let files = try proposedFiles(store: store)
        guard !files.isEmpty else {
            throw ScanError("no proposed records found — run `index label-prep` and write records into <bundle>/proposed/")
        }

        var accepted = 0, rejected = 0
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            let records: [CapabilityRecord]
            do {
                records = try Self.decodeRecords(data)
            } catch {
                rejected += 1
                print(Style.red("   ✗ \(file.lastPathComponent): not a CapabilityRecord — \(error.localizedDescription)"))
                continue
            }

            for record in records {
                // Load every surface the record touches: home, companions, anchor targets.
                var urls = Set([record.package.canonicalURL])
                urls.formUnion(record.requiresCompanion)
                for claim in record.platforms.values {
                    urls.formUnion(claim.evidence.compactMap(\.package))
                }
                var surfaces: [String: PackageSurface] = [:]
                var digests: [String: String] = [:]
                for url in urls {
                    let path = store.surfaceFile(for: url).path
                    guard let surfaceData = FileManager.default.contents(atPath: path) else { continue }
                    surfaces[url] = try? JSONDecoder().decode(PackageSurface.self, from: surfaceData)
                    digests[url] = ContentDigest.fnv1a64(surfaceData)
                }

                let result = RecordValidator.validate(record, surfaces: surfaces.compactMapValues { $0 },
                                                      digests: digests, taxonomy: taxonomyFile)
                let label = "\(record.package.name) × \(record.capability.id)"
                for diagnostic in result.diagnostics {
                    let paint = diagnostic.severity == .error ? Style.red : Style.yellow
                    print(paint("     [\(diagnostic.rule)] \(diagnostic.message)"))
                }
                if result.isAccepted {
                    accepted += 1
                    print(Style.green("   ✓ \(label)") + (promote ? "" : Style.dim("  (re-run with --promote to land it)")))
                    if promote {
                        try promoteRecord(record)
                    }
                } else {
                    rejected += 1
                    print(Style.red("   ✗ \(label) — \(result.errors.count) error\(result.errors.count == 1 ? "" : "s")"))
                }
            }
        }

        print(Style.bold("🍦 validate complete") + " — \(accepted) accepted, \(rejected) rejected")
        if rejected > 0 { throw ExitCode(1) }
    }

    private func proposedFiles(store: CorpusStore) throws -> [URL] {
        let fm = FileManager.default
        if let proposed {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: proposed, isDirectory: &isDir) else {
                throw ScanError("no such file or directory: \(proposed)")
            }
            if !isDir.boolValue { return [URL(fileURLWithPath: proposed)] }
            return jsonFiles(in: URL(fileURLWithPath: proposed))
        }
        guard let bundles = try? fm.contentsOfDirectory(at: store.labeling, includingPropertiesForKeys: nil) else {
            return []
        }
        return bundles.flatMap { jsonFiles(in: $0.appendingPathComponent("proposed")) }
    }

    private func jsonFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
    }

    static func decodeRecords(_ data: Data) throws -> [CapabilityRecord] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([CapabilityRecord].self, from: data) { return array }
        return [try decoder.decode(CapabilityRecord.self, from: data)]
    }

    /// Every record under a root — flat files and one level of domain
    /// subdirectories (`data/records/audio/*.json`, `data/records/network/…`).
    fileprivate static func mergeRecordFiles(_ recordsRoot: String) throws -> [CapabilityRecord] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: recordsRoot)
        var files: [URL] = []
        for entry in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []) {
            if entry.pathExtension == "json" {
                files.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }
            }
        }
        var all: [CapabilityRecord] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let data = fm.contents(atPath: file.path) else { continue }
            all += try decodeRecords(data)
        }
        return all.sorted {
            ($0.package.canonicalURL, $0.capability.id) < ($1.package.canonicalURL, $1.capability.id)
        }
    }

    private func promoteRecord(_ record: CapabilityRecord) throws {
        let slug = CorpusStore.slug(for: record.package.canonicalURL)
        let path = "\(recordsDir)/\(slug).json"
        var existing = (FileManager.default.contents(atPath: path)).flatMap { try? Self.decodeRecords($0) } ?? []
        existing.removeAll { $0.capability.id == record.capability.id }
        existing.append(record)
        existing.sort { $0.capability.id < $1.capability.id }
        try CorpusFiles.writeJSON(existing, to: path)
        print(Style.dim("     → \(path)"))
    }
}

// MARK: - assemble

struct Assemble: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bundle every domain's validated records + taxonomies into the query dataset the CLI ships."
    )

    @Option(name: .long, help: "Root of accepted records (domain subdirs are scanned).")
    var recordsRoot: String = "data/records"

    @Option(name: .long, help: "Directory of per-domain taxonomy files (merged).")
    var taxonomyDir: String = "data/taxonomy"

    @Option(name: .long, help: "Dataset output (bundled into the CLI on rebuild).")
    var out: String = "Sources/SwiftServeCLI/Resources/capability-dataset.json"

    func run() throws {
        let taxonomy = try Self.mergedTaxonomy(taxonomyDir)
        let records = try Validate.mergeRecordFiles(recordsRoot)
        let dataset = CapabilityDataset(taxonomy: taxonomy, records: records)
        try CorpusFiles.writeJSON(dataset, to: out)
        let packages = Set(records.map(\.package.canonicalURL)).count
        print(Style.bold("🍦 dataset assembled") + " — \(records.count) record\(records.count == 1 ? "" : "s") across \(packages) package\(packages == 1 ? "" : "s"), \(dataset.taxonomy.capabilities.count) capabilities (\(dataset.taxonomy.domain)) → \(out)")
        print(Style.dim("   rebuild (`swift build`) to bundle it into the CLI"))
    }

    static func mergedTaxonomy(_ dir: String) throws -> Taxonomy {
        let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                                   includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw ScanError("no taxonomy files in \(dir)") }
        let taxonomies = try files.map { file -> Taxonomy in
            guard let data = FileManager.default.contents(atPath: file.path) else {
                throw ScanError("couldn't read \(file.path)")
            }
            return try Taxonomy.decode(from: data)
        }
        return try Taxonomy.merged(taxonomies)
    }
}
