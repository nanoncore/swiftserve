import ArgumentParser
import Foundation
import SwiftServeCore
import SwiftServeBuild

/// `swiftserve build-cost [dir]` — Pillar 3, slice 5. Builds a SwiftPM project with frontend
/// timing stats on, then attributes the compile cost to your own targets and to each dependency
/// PACKAGE, ranked and crossed with the dependency's offline health. Answers "which dependency
/// is expensive to build, and is it worth it?" — and "which of my targets is the slowest?".
///
/// Cost is total frontend wall (sema + SILGen + IRGen + …) summed per module from
/// `-stats-output-dir`. It is compile *work*, not wall-clock (frontend jobs run in parallel), so
/// it is only ever presented as a share of the whole build. Runs locally; nothing leaves the
/// machine — health is the file-only score.
struct BuildCost: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-cost",
        abstract: "Rank what your build spends compiling — your targets and your dependency packages — crossed with health.",
        discussion: """
        Drives `swift build` with -stats-output-dir, sums each module's frontend wall time,
        rolls dependency modules up to their package, and ranks everything by share of the
        build. Dependencies are crossed with their offline (file-only) health score, so the
        only "reconsider this dependency" callout is for packages that are both expensive
        AND unhealthy.

        Building takes as long as your build does. For full coverage pass --clean (a cached
        build only re-emits stats for what it recompiled). To re-analyze without building,
        point --stats-dir at an existing -stats-output-dir.

        NOTE  Cost is compile *work* (parallel jobs), shown as share-of-build, never as
        "seconds added to your build". Prebuilt/binary dependencies show no compile cost.

        EXIT CODES
          0  reported successfully    2  couldn't measure (no Package.swift, build failed)
        """
    )

    @Argument(help: "The SwiftPM project directory to build (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable card.")
    var card = false

    @Flag(name: .long, help: "Run `swift package clean` first so every module recompiles (full coverage).")
    var clean = false

    @Option(name: .long, help: "Analyze an existing -stats-output-dir instead of driving a build.")
    var statsDir: String?

    @Option(name: .long, help: "Path to Package.resolved for health (defaults to <dir>/Package.resolved).")
    var resolved: String?

    @Option(name: .long, help: "Detail at most this many dependencies in the card (JSON always carries all).")
    var top: Int?

    func run() throws {
        var cfg = CostConfig.default
        if let top { cfg = cfg.with(topN: max(1, top)) }
        let packageDir = path ?? "."
        var warnings: [String] = []

        // 1. Acquire a stats directory — the only process-spawning step.
        let statsPath: String
        let mode: String
        var cleanup: (() -> Void)?
        if let statsDir {
            mode = "stats-dir"
            statsPath = statsDir
            warnings.append("Analyzed an existing stats directory — results reflect whatever that build compiled.")
        } else {
            mode = "build"
            let outcome: CostBuildRunner.Outcome
            do {
                outcome = try CostBuildRunner.run(packagePath: packageDir, clean: clean)
            } catch let e as ScanError {
                try fail(e.message)
            }
            if !outcome.succeeded {
                try fail("build failed — fix the build first, then re-run for cost:\n" + BuildRunner.errorTail(outcome.output))
            }
            statsPath = outcome.statsDir
            cleanup = { try? FileManager.default.removeItem(atPath: outcome.statsDir) }
        }
        defer { cleanup?() }

        // 2. Aggregate per-module frontend cost (pure-ish read), then attribute modules to owners.
        let stats = StatsAggregator.aggregate(dir: statsPath)
        if stats.isEmpty {
            warnings.append("No -stats-output-dir data found — this toolchain may not emit it, or nothing recompiled.")
        }
        let firstParty = ModuleAttributor.firstPartyTargets(packageDir: packageDir)
        let attribution = ModuleAttributor.attribute(modules: stats, packageDir: packageDir, firstPartyTargets: firstParty)
        let timings = stats.map { s -> ModuleTiming in
            let a = attribution[s.module] ?? ModuleAttribution(origin: .unattributed, packageIdentity: nil)
            return ModuleTiming(module: s.module, packageIdentity: a.packageIdentity, origin: a.origin,
                                frontendWallMs: s.frontendMs, typeCheckWallMs: s.typeCheckMs)
        }

        // A build that emitted stats for nothing is a cached build (only in build mode — an
        // explicit stats-dir is whatever the user handed us).
        let compiledModules: Int? = (mode == "build") ? stats.count : nil
        let context = BuildContext(buildSucceeded: true, compiledUnits: compiledModules,
                                   totalTypeCheckMs: nil, source: mode == "build" ? .build : .log)
        if mode == "build", stats.isEmpty == false, compiledModules == 0, !clean {
            warnings.append("Looks like a cached build (nothing recompiled) — re-run with --clean for full per-dependency cost.")
        }

        // 3. Cross with offline (file-only) dependency health.
        let resolvedPath = resolved ?? (packageDir as NSString).appendingPathComponent("Package.resolved")
        let (health, healthWarning) = Self.loadHealth(resolvedPath: resolvedPath)
        if let healthWarning { warnings.append(healthWarning) }

        let unattributed = timings.filter { $0.origin == .unattributed }.count
        if unattributed > 0 {
            warnings.append("Couldn't map \(unattributed) module\(unattributed == 1 ? "" : "s") to a package — grouped as unattributed.")
        }

        // 4. Analyze (pure) → assemble → output.
        let result = BuildCostAnalyzer.analyze(timings: timings, health: health, context: context, config: cfg)
        let report = BuildCostReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            target: .init(path: packageDir, mode: mode, buildSucceeded: true, compiledModules: compiledModules),
            swiftee: result.verdict, summary: result.summary, entries: result.entries, warnings: warnings)

        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderBuildCostCard(report, detailedDeps: cfg.topN))
        }
    }

    // MARK: - Offline health (file-only, like the web path — zero network)

    static func loadHealth(resolvedPath: String) -> ([String: DependencyHealth], String?) {
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            return ([:], "No Package.resolved at \(resolvedPath) — cost shown without dependency health.")
        }
        do {
            let pins = try PackageResolvedParser().parse(data)
            let report = Scorer(config: .default).buildReport(
                pins: pins, enrichment: [:], source: "fileOnly", networkUsed: false,
                generatedAt: ISO8601DateFormatter().string(from: Date()))
            var map: [String: DependencyHealth] = [:]
            for p in report.packages {
                map[p.identity] = DependencyHealth(identity: p.identity, score: p.score,
                                                   flags: p.flags, version: p.resolvedVersion)
            }
            return (map, nil)
        } catch {
            return ([:], "Couldn't read Package.resolved for health (\(error)) — cost shown without it.")
        }
    }

    // MARK: - Output (same conventions as the other subcommands)

    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
    }

    private static func encodeJSON(_ report: BuildCostReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    private func fail(_ message: String) throws -> Never {
        let line: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if wantsJSON, let d = try? encoder.encode(["error": message]), let s = String(data: d, encoding: .utf8) {
            line = s
        } else {
            line = "Error: \(message)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        throw ExitCode(2)
    }
}

// MARK: - Driving the build (process boundary; keeps the stats dir for the caller)

/// Spawns `swift build` with only `-stats-output-dir` (a stable path under `.build`, so a stable
/// command line keeps incremental caching intact). Unlike `BuildRunner`, it does NOT delete the
/// stats dir — `build-cost` reads it, then cleans up. The only place in this command that touches
/// a process.
enum CostBuildRunner {
    struct Outcome {
        let statsDir: String
        let succeeded: Bool
        let output: String
    }

    static func run(packagePath: String, clean: Bool) throws -> Outcome {
        let manifest = (packagePath as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest) else {
            throw ScanError("not a SwiftPM project: no Package.swift in \(packagePath)")
        }
        if clean { _ = runSwift(["package", "clean", "--package-path", packagePath]) }

        let statsDir = (packagePath as NSString).appendingPathComponent(".build/swiftserve-cost-stats")
        try? FileManager.default.removeItem(atPath: statsDir)
        try? FileManager.default.createDirectory(atPath: statsDir, withIntermediateDirectories: true)

        let (output, code) = runSwift([
            "build", "--package-path", packagePath,
            "-Xswiftc", "-stats-output-dir", "-Xswiftc", statsDir,
        ])
        return Outcome(statsDir: statsDir, succeeded: code == 0, output: output)
    }

    /// Run `xcrun swift …`, merging stdout+stderr; read to EOF before waiting (avoid pipe deadlock).
    private static func runSwift(_ args: [String]) -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

// MARK: - Reading -stats-output-dir into per-module costs

/// Aggregates a `-stats-output-dir` directory into per-module frontend cost. Each emitted JSON is
/// one frontend invocation tagged in its filename with the module; the single
/// `time.swift-frontend.*.wall` counter is that whole job's wall time (no double-counting), and
/// `time.swift.Type checking and Semantic analysis.wall` is the type-check subset. Source-file
/// basenames are collected for attribution.
enum StatsAggregator {
    struct ModuleStat {
        let module: String
        var frontendMs: Int
        var typeCheckMs: Int
        var files: [String]
    }

    static func aggregate(dir: String) -> [ModuleStat] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var acc: [String: ModuleStat] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let (module, file) = parseName(name) else { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: full),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var s = acc[module] ?? ModuleStat(module: module, frontendMs: 0, typeCheckMs: 0, files: [])
            s.frontendMs += frontendWallMs(obj)
            s.typeCheckMs += msFor(obj, "time.swift.Type checking and Semantic analysis.wall")
            if let file, file.hasSuffix(".swift") { s.files.append(file) }
            acc[module] = s
        }
        return Array(acc.values)
    }

    /// `stats-<ts>-swift-frontend-<MODULE>-<FILE|all>-<arch>-…json` → (module, file). Module names
    /// are dash-free identifiers, so they're the single token after `swift-frontend-`.
    static func parseName(_ name: String) -> (String, String?)? {
        guard let r = name.range(of: "swift-frontend-") else { return nil }
        let rest = String(name[r.upperBound...])
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let module = String(rest[..<dash])
        let afterModule = String(rest[rest.index(after: dash)...])
        // The file token runs up to the arch marker (`-arm64…` / `-x86_64…`).
        var file = afterModule
        for marker in ["-arm64", "-x86_64"] {
            if let m = file.range(of: marker) { file = String(file[..<m.lowerBound]) }
        }
        return (module, file.isEmpty ? nil : file)
    }

    /// The single whole-job wall counter (`time.swift-frontend.<job>.wall`), in ms. Values are
    /// seconds on disk. Max-not-sum guards against any stray duplicate prefix match.
    private static func frontendWallMs(_ obj: [String: Any]) -> Int {
        var best = 0.0
        for (k, v) in obj where k.hasPrefix("time.swift-frontend.") && k.hasSuffix(".wall") {
            if let n = v as? NSNumber { best = max(best, n.doubleValue) }
        }
        return Int((best * 1000).rounded())
    }

    private static func msFor(_ obj: [String: Any], _ key: String) -> Int {
        guard let n = obj[key] as? NSNumber else { return 0 }
        return Int((n.doubleValue * 1000).rounded())
    }
}

// MARK: - Attributing modules to owners (your targets, dependency packages, or unattributed)

struct ModuleAttribution {
    let origin: CostOrigin
    let packageIdentity: String?
}

/// Maps each compiled module to its owner. The authoritative signal is *where its source files
/// physically live*: a basename→owner index built from the on-disk source trees, majority-voted
/// per module. This handles packages whose source directory differs from the module name (e.g.
/// swift-system's `SystemPackage` lives under `Sources/System`). Falls back to the
/// `Sources/<Module>` convention (for modules with only emit jobs this run), then unattributed.
enum ModuleAttributor {
    private enum Owner: Hashable { case firstParty; case dependency(String) }

    static func firstPartyTargets(packageDir: String) -> Set<String> {
        let src = (packageDir as NSString).appendingPathComponent("Sources")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: src) else { return [] }
        var set = Set<String>()
        for e in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: (src as NSString).appendingPathComponent(e), isDirectory: &isDir), isDir.boolValue {
                set.insert(e)
            }
        }
        return set
    }

    static func attribute(modules: [StatsAggregator.ModuleStat], packageDir: String,
                          firstPartyTargets: Set<String>) -> [String: ModuleAttribution] {
        let checkouts = (packageDir as NSString).appendingPathComponent(".build/checkouts")
        let index = buildBasenameIndex(checkouts: checkouts, packageDir: packageDir)
        let checkoutDirs = (try? FileManager.default.contentsOfDirectory(atPath: checkouts)) ?? []
        var out: [String: ModuleAttribution] = [:]
        for m in modules {
            out[m.module] = resolve(m, index: index, firstPartyTargets: firstPartyTargets,
                                    checkouts: checkouts, checkoutDirs: checkoutDirs)
        }
        return out
    }

    private static func resolve(_ m: StatsAggregator.ModuleStat, index: [String: Set<Owner>],
                                firstPartyTargets: Set<String>, checkouts: String,
                                checkoutDirs: [String]) -> ModuleAttribution {
        // 1. A first-party target by name is unambiguous.
        if firstPartyTargets.contains(m.module) {
            return ModuleAttribution(origin: .yourTarget, packageIdentity: nil)
        }
        // 2. Majority vote over where this module's source files live.
        var votes: [Owner: Int] = [:]
        for f in m.files { for o in index[f] ?? [] { votes[o, default: 0] += 1 } }
        if let best = votes.max(by: { $0.value < $1.value })?.key {
            switch best {
            case .firstParty: return ModuleAttribution(origin: .yourTarget, packageIdentity: nil)
            case .dependency(let id): return ModuleAttribution(origin: .dependency, packageIdentity: id)
            }
        }
        // 3. Convention fallback: a checkout with a Sources/<Module> directory.
        if let pkg = checkoutDirs.first(where: {
            dirExists((checkouts as NSString).appendingPathComponent("\($0)/Sources/\(m.module)"))
        }) {
            return ModuleAttribution(origin: .dependency, packageIdentity: pkg)
        }
        // 4. Couldn't tie it to anyone — surfaced, never dropped.
        return ModuleAttribution(origin: .unattributed, packageIdentity: nil)
    }

    private static func buildBasenameIndex(checkouts: String, packageDir: String) -> [String: Set<Owner>] {
        var index: [String: Set<Owner>] = [:]
        let fm = FileManager.default
        if let pkgs = try? fm.contentsOfDirectory(atPath: checkouts) {
            for pkg in pkgs {
                indexSwift(in: (checkouts as NSString).appendingPathComponent("\(pkg)/Sources"),
                           owner: .dependency(pkg), into: &index, fm: fm)
            }
        }
        indexSwift(in: (packageDir as NSString).appendingPathComponent("Sources"),
                   owner: .firstParty, into: &index, fm: fm)
        return index
    }

    private static func indexSwift(in root: String, owner: Owner,
                                   into index: inout [String: Set<Owner>], fm: FileManager) {
        guard let en = fm.enumerator(atPath: root) else { return }
        for case let rel as String in en where rel.hasSuffix(".swift") {
            index[(rel as NSString).lastPathComponent, default: []].insert(owner)
        }
    }

    private static func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
