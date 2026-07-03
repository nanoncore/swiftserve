import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftServeCapability
import SwiftServeCore
import SwiftServeSurface

/// `swiftserve index` — the founder-facing corpus pipeline: discover a
/// domain's packages, fetch them at pinned tags, extract their surfaces.
/// All the impure work (network, git, disk) lives here; everything it
/// produces is plain JSON the pure layers consume.
struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build the capability corpus: discover, fetch, extract, probe, label, validate.",
        subcommands: [Discover.self, Fetch.self, Extract.self, BuildProbe.self, SdkExtract.self, LabelPrep.self, Validate.self, Assemble.self]
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
    var builds: URL { root.appendingPathComponent("builds") }

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

// MARK: - build-probe

/// `swiftserve index build-probe` — compile the truth. Builds each fetched
/// checkout for a platform against the real SDK and writes the outcome as a
/// `BuildVerdict` artifact (in-repo truth, like records). `buildVerdict`
/// anchors in records cite these; the validator matches commit + outcome.
struct BuildProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-probe",
        abstract: "Compile checkouts for a platform (xcodebuild) and write build-verdict artifacts."
    )

    @Option(name: .long, help: "Probe only this package (owner/repo or URL fragment).")
    var package: String?

    @Option(name: .long, help: "Platform to probe (iOS/macOS/tvOS/watchOS/visionOS/macCatalyst).")
    var platform: String = "visionOS"

    @Option(name: .long, help: "Corpus JSON produced by `index discover`.")
    var corpus: String = CorpusFiles.defaultCorpus

    @Option(name: .long, help: "Where verdict artifacts land, one per package × platform.")
    var out: String = "data/build-verdicts"

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    @Flag(name: .long, help: "Re-probe even when a verdict already exists at the pinned commit.")
    var force = false

    private static let destinations: [String: String] = [
        "iOS": "generic/platform=iOS",
        "macOS": "generic/platform=macOS",
        "tvOS": "generic/platform=tvOS",
        "watchOS": "generic/platform=watchOS",
        "visionOS": "generic/platform=visionOS",
        "macCatalyst": "generic/platform=macOS,variant=Mac Catalyst",
    ]
    private static let sdkNames: [String: String] = [
        "iOS": "iphoneos", "macOS": "macosx", "tvOS": "appletvos",
        "watchOS": "watchos", "visionOS": "xros", "macCatalyst": "macosx",
    ]

    func run() throws {
        guard let destination = Self.destinations[platform] else {
            throw ScanError("can't probe ‘\(platform)’ — xcodebuild reaches \(Self.destinations.keys.sorted().joined(separator: "/")) only")
        }
        let store = CorpusStore(override: corpusDir)
        let corpusFile = try CorpusFiles.read(corpus, as: Corpus.decode)

        var targets = corpusFile.packages.filter {
            FileManager.default.fileExists(atPath: store.checkoutDir(for: $0.url).path)
        }
        if let package {
            targets = targets.filter { $0.url.localizedCaseInsensitiveContains(package) }
            guard !targets.isEmpty else { throw ScanError("no fetched corpus package matches ‘\(package)’") }
        }

        let toolchain = Self.xcodeVersion()
        let sdk = Self.sdkBasename(for: platform)
        let stamp = ISO8601DateFormatter().string(from: Date())
        var built = 0, failed = 0, inconclusive = 0, skipped = 0

        for candidate in targets {
            let slug = CorpusStore.slug(for: candidate.url)
            let checkout = store.checkoutDir(for: candidate.url)
            let commit = ((try? GitRunner.run(["rev-parse", "HEAD"], cwd: checkout.path)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let verdictPath = "\(out)/\(slug).\(platform).json"

            if !force, let data = FileManager.default.contents(atPath: verdictPath),
               let existing = try? BuildVerdict.decode(from: data), existing.commit == commit {
                skipped += 1
                print(Style.dim("   ~ \(candidate.name): verdict exists at \(commit.prefix(8)) — --force to re-probe"))
                continue
            }

            let verdict = probe(candidate: candidate, slug: slug, checkout: checkout, commit: commit,
                                destination: destination, toolchain: toolchain, sdk: sdk,
                                store: store, stamp: stamp)
            try CorpusFiles.writeJSON(verdict, to: verdictPath)
            let first = verdict.errorExcerpt.first ?? "no error line captured"
            switch verdict.outcome {
            case .built:
                built += 1
                print(Style.green("   ✓ \(candidate.name) builds for \(platform)") + Style.dim("  (\(verdict.scheme))"))
            case .failed:
                failed += 1
                print(Style.red("   ✗ \(candidate.name) fails for \(platform)") + Style.dim("  \(first.prefix(100))"))
            case .inconclusive:
                inconclusive += 1
                print(Style.yellow("   ~ \(candidate.name) probe inconclusive") + Style.dim("  \(first.prefix(100))"))
            }
        }

        print(Style.bold("🍦 build-probe complete")
              + " — \(built) built, \(failed) failed, \(inconclusive) inconclusive, \(skipped) already probed → \(out)/")
    }

    /// One package's probe: copy the checkout (never build in the pristine
    /// tree), pick a scheme, build for the destination, distill the receipt.
    private func probe(candidate: DomainCandidate, slug: String, checkout: URL, commit: String,
                       destination: String, toolchain: String, sdk: String,
                       store: CorpusStore, stamp: String) -> BuildVerdict {
        let fm = FileManager.default
        let buildDir = store.builds.appendingPathComponent(slug)
        defer { try? fm.removeItem(at: buildDir) }

        func verdict(_ outcome: BuildVerdict.Outcome, scheme: String, errors: [String] = []) -> BuildVerdict {
            BuildVerdict(canonicalURL: candidate.url, commit: commit, platform: platform,
                         outcome: outcome, toolchain: toolchain, sdk: sdk, destination: destination,
                         scheme: scheme, errorExcerpt: errors, probedAt: stamp)
        }

        do {
            try? fm.removeItem(at: buildDir)
            try fm.createDirectory(at: store.builds, withIntermediateDirectories: true)
            try fm.copyItem(at: checkout, to: buildDir)
            try? fm.removeItem(at: buildDir.appendingPathComponent(".git"))
            // We probe the PACKAGE. A checked-in xcodeproj/xcworkspace would
            // hijack `xcodebuild -list` with the repo's own (often iOS-only)
            // schemes — the SwiftySound lesson.
            for item in (try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil)) ?? []
            where ["xcodeproj", "xcworkspace"].contains(item.pathExtension) {
                try? fm.removeItem(at: item)
            }
        } catch {
            return verdict(.inconclusive, scheme: "", errors: ["probe setup failed: \(error.localizedDescription)"])
        }

        let scheme = chooseScheme(in: buildDir, packageName: candidate.name)
        guard !scheme.isEmpty else {
            return verdict(.inconclusive, scheme: "", errors: ["xcodebuild -list found no schemes"])
        }

        let result = ToolRunner.run("xcodebuild", [
            "build", "-scheme", scheme, "-destination", destination,
            "-derivedDataPath", buildDir.appendingPathComponent(".dd").path,
            "-skipPackagePluginValidation", "-skipMacroValidation",
            "CODE_SIGNING_ALLOWED=NO",
        ], cwd: buildDir.path)

        if result.status == 0 { return verdict(.built, scheme: scheme) }
        let errors = Self.errorLines(result.output, stripping: buildDir.path)
        // `xcodebuild: error:` lines are harness trouble (bad destination,
        // missing scheme), not the package failing to compile — and a missing
        // local toolchain component (Metal) is OUR gap, never package truth.
        // A failure with no compiler error at all is the probe's fault too.
        if errors.contains(where: { $0.contains("missing Metal Toolchain") }) {
            return verdict(.inconclusive, scheme: scheme, errors: errors)
        }
        let compilerErrors = errors.filter { !$0.hasPrefix("xcodebuild: error:") }
        guard !compilerErrors.isEmpty else {
            return verdict(.inconclusive, scheme: scheme,
                           errors: errors.isEmpty ? ["build failed with no error line captured"] : errors)
        }
        return verdict(.failed, scheme: scheme, errors: compilerErrors)
    }

    /// `xcodebuild -list` reports schemes for the whole resolved workspace —
    /// DEPENDENCIES included — so picking by name alone can silently build
    /// someone else's product (the swift-midi-io lesson: its probe built the
    /// dep scheme `swift-midi-core`). Intersect schemes with THIS package's
    /// own products from `swift package dump-package`, libraries first.
    private func chooseScheme(in dir: URL, packageName: String) -> String {
        let result = ToolRunner.run("xcodebuild", ["-list", "-json"], cwd: dir.path)
        // stderr is merged into the pipe and xcodebuild logs chatter before
        // the JSON — parse from the first brace.
        guard result.status == 0, let brace = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(
                with: Data(result.output[brace...].utf8)) as? [String: Any] else {
            return ""
        }
        let container = (json["workspace"] ?? json["project"]) as? [String: Any]
        let schemes = container?["schemes"] as? [String] ?? []
        let repo = packageName.split(separator: "/").last.map(String.init) ?? packageName

        var libraryProducts: [String] = [], otherProducts: [String] = []
        let dump = ToolRunner.run("swift", ["package", "dump-package"], cwd: dir.path)
        if dump.status == 0, let dumpBrace = dump.output.firstIndex(of: "{"),
           let manifest = try? JSONSerialization.jsonObject(
             with: Data(dump.output[dumpBrace...].utf8)) as? [String: Any],
           let products = manifest["products"] as? [[String: Any]] {
            for product in products {
                guard let name = product["name"] as? String else { continue }
                let isLibrary = (product["type"] as? [String: Any])?["library"] != nil
                if isLibrary { libraryProducts.append(name) } else { otherProducts.append(name) }
            }
        }

        for pool in [libraryProducts, otherProducts] {
            let own = schemes.filter { pool.contains($0) }
            if let exact = own.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { return exact }
            if let first = own.first { return first }
        }
        // No product scheme (bare-target package): fall back, aggregates last.
        if let exact = schemes.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { return exact }
        return schemes.first { !$0.hasSuffix("-Package") } ?? schemes.first ?? ""
    }

    private static func errorLines(_ output: String, stripping prefix: String) -> [String] {
        var seen = Set<String>(), lines: [String] = []
        for raw in output.split(separator: "\n") where raw.contains("error: ") {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: prefix + "/", with: "")
            if seen.insert(line).inserted { lines.append(line) }
            if lines.count == 12 { break }
        }
        return lines
    }

    private static func xcodeVersion() -> String {
        guard let (name, build) = ToolRunner.xcodeVersion() else { return "unknown" }
        return "\(name) (\(build))"
    }

    private static func sdkBasename(for platform: String) -> String {
        guard let sdkName = sdkNames[platform] else { return "unknown" }
        let result = ToolRunner.run("xcrun", ["--sdk", sdkName, "--show-sdk-path"])
        guard result.status == 0 else { return sdkName }
        return URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
    }

}

/// xcodebuild/xcrun sibling of `GitRunner`, shared by the probe and the SDK
/// extractor. A nonzero exit is data, not an error — a failed build IS the
/// verdict. Reads the pipe before waiting so a chatty xcodebuild can't
/// deadlock on a full buffer.
enum ToolRunner {
    static func run(_ tool: String, _ arguments: [String], cwd: String = ".") -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// ("Xcode 26.6", "17F113") from `xcodebuild -version`.
    static func xcodeVersion() -> (name: String, build: String)? {
        let result = run("xcodebuild", ["-version"])
        let parts = result.output.split(separator: "\n").map(String.init)
        guard result.status == 0, let name = parts.first else { return nil }
        let build = parts.dropFirst().first?.replacingOccurrences(of: "Build version ", with: "") ?? "?"
        return (name, build)
    }
}

// MARK: - sdk-extract

/// `swiftserve index sdk-extract` — the first-party corpus. Apple frameworks
/// have no repo to pin, but they have parseable truth: the toolchain's
/// `swift-symbolgraph-extract` emits every public symbol a platform SDK
/// exports — ObjC-imported API included — with availability per platform.
/// One graph per SDK, merged (membership + @available overlays decide
/// presence), written as a surface the SAME record/validator machinery
/// consumes — the pin is the Xcode build.
struct SdkExtract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk-extract",
        abstract: "Extract Apple framework surfaces from installed platform SDKs (symbol graphs)."
    )

    @Argument(help: "Framework module names (e.g. AVFAudio CoreMIDI SoundAnalysis).")
    var frameworks: [String]

    @Option(name: .long, help: "Corpus cache directory (default: ~/Library/Caches/swiftserve/corpus; env SWIFTSERVE_CORPUS).")
    var corpusDir: String?

    private static let sdks: [(platform: Platform, sdk: String, tripleOS: String)] = [
        (.iOS, "iphoneos", "ios"), (.macOS, "macosx", "macosx"), (.tvOS, "appletvos", "tvos"),
        (.watchOS, "watchos", "watchos"), (.visionOS, "xros", "xros"),
    ]

    func run() throws {
        let store = CorpusStore(override: corpusDir)
        guard let (xcodeName, xcodeBuild) = ToolRunner.xcodeVersion() else {
            throw ScanError("xcodebuild -version failed — is Xcode installed?")
        }

        var targets: [(platform: Platform, sdkPath: String, triple: String)] = []
        for entry in Self.sdks {
            let path = ToolRunner.run("xcrun", ["--sdk", entry.sdk, "--show-sdk-path"])
            let version = ToolRunner.run("xcrun", ["--sdk", entry.sdk, "--show-sdk-version"])
            guard path.status == 0, version.status == 0 else { continue }
            targets.append((entry.platform,
                            path.output.trimmingCharacters(in: .whitespacesAndNewlines),
                            "arm64-apple-\(entry.tripleOS)\(version.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        guard !targets.isEmpty else { throw ScanError("no platform SDKs found — install Xcode platforms first") }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftserve-symbolgraph-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var extracted = 0
        for framework in frameworks {
            var perPlatform: [Platform: [SurfaceDecl]] = [:]
            var graphs = 0
            for target in targets {
                let outDir = tmp.appendingPathComponent("\(framework)-\(target.triple)")
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let result = ToolRunner.run("xcrun", [
                    "swift-symbolgraph-extract", "-module-name", framework,
                    "-target", target.triple, "-sdk", target.sdkPath,
                    "-output-dir", outDir.path, "-minimum-access-level", "public",
                ])
                // A missing module on this platform is membership truth, not an error.
                guard result.status == 0,
                      let data = FileManager.default.contents(
                        atPath: outDir.appendingPathComponent("\(framework).symbols.json").path) else { continue }
                let file = "symbolgraph/\(target.triple)/\(framework).symbols.json"
                perPlatform[target.platform] = try SymbolGraphParser.decls(from: data, file: file)
                graphs += 1
            }
            guard !perPlatform.isEmpty else {
                print(Style.red("   ✗ \(framework): no platform SDK exports this module"))
                continue
            }

            let merged = SDKSurfaceMerger.merge(perPlatform: perPlatform)
            let canonicalURL = "https://developer.apple.com/documentation/\(framework.lowercased())"
            let surface = PackageSurface(
                package: PackageProvenance(canonicalURL: canonicalURL, name: framework,
                                           tag: xcodeName, commit: xcodeBuild),
                manifestPlatforms: [],
                decls: merged,
                stats: SurfaceStats(swiftFiles: graphs, objcFiles: 0, declCount: merged.count,
                                    parseFailures: 0, manifestUnparsed: false, hasBinaryTargets: false))
            try FileManager.default.createDirectory(at: store.surfaces, withIntermediateDirectories: true)
            try Data((try SurfaceBuilder.encodeJSON(surface) + "\n").utf8)
                .write(to: store.surfaceFile(for: canonicalURL))
            extracted += 1
            let onVision = merged.filter { $0.resolvedPlatforms?["visionOS"] == .present }.count
            print("   ✓ \(framework): \(merged.count) symbols from \(graphs) SDK graphs, \(onVision) present on visionOS")
        }
        print(Style.bold("🍦 sdk-extract complete") + " — \(extracted) framework surfaces @ \(xcodeName) (\(xcodeBuild))")
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

    @Option(name: .long, help: "Build-verdict artifacts records may cite (from `index build-probe`).")
    var buildVerdicts: String = "data/build-verdicts"

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

        // Build verdicts are optional truth: load whatever artifacts exist.
        var verdicts: [String: BuildVerdict] = [:]
        let verdictFiles = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: buildVerdicts), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        for file in verdictFiles {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let verdict = try? BuildVerdict.decode(from: data) else { continue }
            verdicts[verdict.key] = verdict
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
                                                      digests: digests, buildVerdicts: verdicts,
                                                      taxonomy: taxonomyFile)
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
