import ArgumentParser
import Foundation
import SwiftServeBuild

/// `swiftserve build-timing [dir]` — Pillar 3, slice 4. Builds a SwiftPM project with
/// Swift's type-check-timing instrumentation on, then points at the slowest expressions and
/// function bodies to compile — each with an exact location and a concrete fix. These are
/// *pointers* (suggestions), not findings: the register is "here's a quick win", never a
/// scolding. Runs locally; nothing leaves the machine.
struct BuildTiming: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-timing",
        abstract: "Build with type-check timing on and rank the slowest-to-compile expressions and function bodies.",
        discussion: """
        Drives `swift build` with -warn-long-expression-type-checking and
        -warn-long-function-bodies (plus -stats-output-dir for the headline total),
        parses the timing warnings, and reports a ranked list of the worst offenders.

        Building takes as long as your build does. For full coverage pass --clean (a
        cached/incremental build only re-warns the files it recompiled). To skip driving
        the build entirely, feed an existing build log with --log.

        EXIT CODES
          0  reported successfully    2  couldn't measure (no Package.swift, build failed)
        """
    )

    @Argument(help: "The SwiftPM project directory to build (defaults to the current directory). Ignored with --log.")
    var path: String?

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable summary.")
    var card = false

    @Option(name: .long, help: "Parse an existing build log instead of driving the build. Use '-' for stdin.")
    var log: String?

    @Flag(name: .long, help: "Run `swift package clean` first so every file recompiles (full coverage).")
    var clean = false

    @Option(name: .long, help: "Override the slow-expression threshold, in milliseconds.")
    var exprThreshold: Int?

    @Option(name: .long, help: "Override the slow-function-body threshold, in milliseconds.")
    var bodyThreshold: Int?

    @Option(name: .long, help: "Detail at most this many pointers in the card (JSON always carries all).")
    var top: Int?

    @Option(name: .long, help: "Use a custom timing config JSON instead of the bundled defaults.")
    var config: String?

    func run() throws {
        // 1. Load the tunables (data), then layer CLI overrides on top.
        var cfg: TimingConfig
        let configWarning: String?
        do {
            (cfg, configWarning) = try loadConfig()
        } catch let e as ScanError {
            try fail(e.message)
        }
        if let exprThreshold { cfg = cfg.with(expressionThresholdMs: exprThreshold) }
        if let bodyThreshold { cfg = cfg.with(functionBodyThresholdMs: bodyThreshold) }
        if let top { cfg = cfg.with(topN: max(1, top)) }

        // 2. Acquire the timing text + build context — the ONLY I/O in this command.
        var warnings: [String] = []
        if let configWarning { warnings.append(configWarning) }
        let text: String
        let context: BuildContext
        let targetPath: String
        let mode: String

        if let log {
            mode = "log"
            targetPath = log == "-" ? "<stdin>" : log
            do { text = try readLog(log) } catch let e as ScanError { try fail(e.message) }
            context = BuildContext(buildSucceeded: true, compiledUnits: nil, totalTypeCheckMs: nil, source: .log)
            warnings.append("Parsed an existing build log — results reflect whatever that build compiled, "
                + "at whatever thresholds it used.")
        } else {
            mode = "build"
            let dir = path ?? "."
            targetPath = dir
            let outcome: BuildRunner.Outcome
            do {
                outcome = try BuildRunner.run(packagePath: dir, config: cfg, clean: clean)
            } catch let e as ScanError {
                try fail(e.message)
            }
            // Build failed → report it plainly, emit NO pointers.
            if !outcome.succeeded {
                try fail("build failed — fix the build first, then re-run for timings:\n"
                    + BuildRunner.errorTail(outcome.output))
            }
            text = outcome.output
            context = BuildContext(buildSucceeded: true, compiledUnits: outcome.compiledUnits,
                                   totalTypeCheckMs: outcome.totalTypeCheckMs, source: .build)
            if outcome.compiledUnits == 0 && !clean {
                warnings.append("Looks like a cached build (nothing recompiled) — re-run with --clean for full coverage.")
            }
            if outcome.totalTypeCheckMs == nil {
                warnings.append("Couldn't read aggregate type-check totals from this toolchain's stats — "
                    + "the headline reflects the flagged sites only.")
            }
        }

        // 3. Parse (pure) → 4. Analyze (pure).
        let records = TimingParser.records(from: text)
        let result = TimingAnalyzer.analyze(records: records, context: context, config: cfg)

        // First-party only this slice — say so when dependency hot spots were set aside.
        let ignored = result.summary.dependencySitesIgnored
        if ignored > 0 {
            warnings.append("Set aside \(ignored) slow site\(ignored == 1 ? "" : "s") in dependencies — "
                + "this slice points only at your own code.")
        }

        // 5. Enrich with a one-line source excerpt where the file is readable (impure).
        let enriched = result.pointers.map { $0.withExcerpt(SourceExcerpt.line(at: $0.location)) }

        // 6. Assemble + output. JSON is the source of truth; the card renders from it.
        let report = BuildTimingReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            target: .init(path: targetPath, mode: mode,
                          buildSucceeded: context.buildSucceeded, compiledUnits: context.compiledUnits),
            swiftee: result.verdict,
            summary: result.summary,
            pointers: enriched,
            warnings: warnings,
            config: .init(config: cfg))

        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderBuildTimingCard(report))
        }
    }

    // MARK: - Config loading (data, like the denylist; soft-falls-back to the code default)

    private func loadConfig() throws -> (TimingConfig, String?) {
        if let config {
            guard let data = FileManager.default.contents(atPath: config) else {
                throw ScanError("couldn't read timing config at \(config)")
            }
            do { return (try TimingConfig.decode(from: data), nil) }
            catch { throw ScanError("invalid timing config at \(config): \(error)") }
        }
        if let url = Bundle.module.url(forResource: "build-timing.config", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "build-timing.config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg = try? TimingConfig.decode(from: data) {
            return (cfg, nil)
        }
        return (.default, "Bundled timing config missing — using built-in defaults.")
    }

    private func readLog(_ path: String) throws -> String {
        if path == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ScanError("couldn't read build log at \(path)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Output helpers (same conventions as the other subcommands)

    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
    }

    private static func encodeJSON(_ report: BuildTimingReport) throws -> String {
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

// MARK: - Driving the build (the process-spawning boundary)

/// Spawns `swift build` with the timing flags, captures its output, and derives the build
/// context (success, how many files recompiled, aggregate type-check time). The only place
/// in the build pillar that touches a process or the disk — everything downstream is pure.
enum BuildRunner {
    struct Outcome {
        let output: String
        let succeeded: Bool
        let compiledUnits: Int
        let totalTypeCheckMs: Int?
    }

    static func run(packagePath: String, config: TimingConfig, clean: Bool) throws -> Outcome {
        let manifest = (packagePath as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest) else {
            throw ScanError("not a SwiftPM project: no Package.swift in \(packagePath)")
        }

        if clean { _ = swift(["package", "clean", "--package-path", packagePath]) }

        // A *stable* dir for -stats-output-dir, under the package's own .build. The path
        // becomes part of the swiftc command line, so a stable path keeps incremental
        // caching intact across runs (a per-run unique path would force a full rebuild every
        // time — and would make the cached-build case below impossible to ever observe). We
        // clear it first so we never read stale stats, and remove it when we're done.
        let statsDir = (packagePath as NSString).appendingPathComponent(".build/swiftserve-stats")
        try? FileManager.default.removeItem(atPath: statsDir)
        try? FileManager.default.createDirectory(atPath: statsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: statsDir) }

        // `-warn-long-*` are frontend-only flags. SwiftPM's own `-Xfrontend` option refuses a
        // value that starts with `-`, so we tunnel each through `-Xswiftc` instead — the
        // driver forwards `-Xfrontend <flag=value>` to the frontend, which accepts the
        // `=`-joined value as a single token. `-stats-output-dir` is a driver flag and rides
        // `-Xswiftc` directly.
        let args = [
            "build", "--package-path", packagePath,
            "-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-expression-type-checking=\(config.expressionThresholdMs)",
            "-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-function-bodies=\(config.functionBodyThresholdMs)",
            "-Xswiftc", "-stats-output-dir", "-Xswiftc", statsDir,
        ]
        let (output, code) = swift(args)
        let succeeded = code == 0
        return Outcome(
            output: output,
            succeeded: succeeded,
            compiledUnits: countCompiledUnits(output),
            totalTypeCheckMs: succeeded ? StatsReader.totalTypeCheckMs(inDir: statsDir) : nil)
    }

    /// The last few error lines of a failed build — enough to show what broke without
    /// dumping the whole transcript.
    static func errorTail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let errors = lines.filter { $0.contains(": error:") || $0.lowercased().hasPrefix("error:") }
        let picked = errors.isEmpty ? Array(lines.suffix(8)) : Array(errors.prefix(8))
        return picked.joined(separator: "\n")
    }

    /// How many source files the build actually compiled. Zero ⇒ a cached/incremental build
    /// with little to measure. We key on SwiftPM's "Compiling … <file>.swift" lines and
    /// require the `.swift` so build-tool plugin lines ("Compiling plugin GenerateManual")
    /// don't read as recompiled source.
    private static func countCompiledUnits(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).reduce(0) {
            $0 + ($1.contains("Compiling ") && $1.contains(".swift") ? 1 : 0)
        }
    }

    /// Run `xcrun swift …`, merging stdout+stderr (timing warnings go to stderr) into one
    /// stream. Reads to EOF before waiting, to avoid pipe-buffer deadlocks.
    private static func swift(_ args: [String]) -> (String, Int32) {
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

/// Best-effort reader for `-stats-output-dir` output. Sums any wall-clock type-check timer
/// it can find across the emitted `*.json` files. Toolchains phrase these counters
/// differently and some emit none — so a miss returns `nil` and the headline falls back to
/// the flagged-site sum, rather than guessing.
enum StatsReader {
    static func totalTypeCheckMs(inDir dir: String) -> Int? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var seconds = 0.0
        var matched = false
        for name in entries where name.hasSuffix(".json") {
            let full = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: full),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (key, value) in obj {
                let k = key.lowercased()
                guard k.contains("wall"),
                      k.contains("typecheck") || k.contains("type-check") || k.contains("type_check"),
                      let num = value as? NSNumber else { continue }
                seconds += num.doubleValue
                matched = true
            }
        }
        guard matched else { return nil }
        return Int((seconds * 1000).rounded())
    }
}

/// Reads a single trimmed source line for a pointer's excerpt. Returns nil when the file
/// isn't readable (e.g. an ingested log referencing paths that aren't on this machine).
enum SourceExcerpt {
    static func line(at loc: CodeLocation) -> String? {
        guard let content = try? String(contentsOfFile: loc.file, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard loc.line >= 1, loc.line <= lines.count else { return nil }
        let trimmed = lines[loc.line - 1].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 140 ? String(trimmed.prefix(139)) + "…" : trimmed
    }
}
