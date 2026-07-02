import ArgumentParser
import Foundation
import SwiftServeCore
import SwiftServeCapability

/// SwiftServe's terminal/CI/agent front door. Same `SwiftServeCore`, same canonical
/// JSON as the web `POST /analyze` — the human card is rendered from that JSON.
@main
struct SwiftServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftserve",
        abstract: "Scan a Package.resolved and get a dependency-health Scoop from Swiftee.",
        discussion: """
        OUTPUT
          A human card on an interactive terminal; the canonical JSON report when
          piped or redirected. Force either with --json / --card.

        EXIT CODES (for scripts and agents)
          0  scan succeeded
          1  scan succeeded but overall score is below --min-score
          2  scan failed (unreadable file, not a Package.resolved, …)

        AGENTS
          `swiftserve scan --json` emits the canonical report on stdout (and a
          {"error": …} envelope on stderr if it fails). `swiftserve schema` prints
          the report's JSON Schema. The same JSON backs the web card and the CLI.

        ENVIRONMENT
          GITHUB_TOKEN     enable live GitHub enrichment (else file-only)
          NO_COLOR         disable ANSI color
          CLICOLOR_FORCE   force ANSI color even when not a TTY
        """,
        version: "0.6.0",
        subcommands: [Scan.self, ScanBinary.self, ScanDeps.self, ScanSource.self, BuildTiming.self, BuildCost.self, Surface.self, Index.self, CapabilityCheck.self, Find.self, Schema.self],
        defaultSubcommand: Scan.self
    )
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a Package.resolved file into a scored report."
    )

    @Argument(help: "Path to Package.resolved. Use '-' for stdin. Defaults to ./Package.resolved.")
    var path: String?

    @Flag(name: .long, help: "Emit the canonical JSON report (the format AI agents consume).")
    var json = false

    @Flag(name: .long, help: "Render the human-readable card.")
    var card = false

    @Flag(name: .long, help: "Force file-only scoring even if GITHUB_TOKEN is set.")
    var fileOnly = false

    @Option(name: .long, help: "Exit with code 1 if the overall score is below this value (CI gate).")
    var minScore: Int?

    func run() async throws {
        let input: Data
        do {
            input = try readInput()
        } catch {
            try fail("couldn't read input (\(path ?? "stdin")): \(error.localizedDescription)")
        }

        let report: Report
        do {
            report = try await makeAnalyzer().analyze(resolved: input)
        } catch let error as PackageResolvedError {
            try fail(error.description)
        } catch {
            try fail("scan failed: \(error.localizedDescription)")
        }

        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderCard(report))
        }

        // The scan itself succeeded; a failed gate is a distinct, expected outcome.
        if let minScore, report.overall.score < minScore {
            throw ExitCode(1)
        }
    }

    // MARK: - Input

    private func readInput() throws -> Data {
        if path == "-" { return readStdin() }
        if let path {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        // No path given: prefer ./Package.resolved, else fall back to stdin (piping).
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.resolved")
        if FileManager.default.fileExists(atPath: local.path) {
            return try Data(contentsOf: local)
        }
        return readStdin()
    }

    private func readStdin() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    // MARK: - Enrichment (mirrors the server)

    private func makeAnalyzer() -> Analyzer {
        if fileOnly { return Analyzer() }
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        if let token, !token.isEmpty {
            return Analyzer(enrichment: GitHubEnrichment(token: token))
        }
        return Analyzer()
    }

    // MARK: - Output

    /// JSON when piped or forced; the card on an interactive terminal.
    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
    }

    private static func encodeJSON(_ report: Report) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    /// Emit a runtime error (JSON envelope when in JSON mode, else a plain line)
    /// to stderr and exit 2 — distinct from the success/gate codes.
    private func fail(_ message: String) throws -> Never {
        let line: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if wantsJSON,
           let data = try? encoder.encode(["error": message]),
           let s = String(data: data, encoding: .utf8) {
            line = s
        } else {
            line = "Error: \(message)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        throw ExitCode(2)
    }
}

/// Print canonical JSON Schemas — lets agents validate/understand output.
struct Schema: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a JSON Schema: report (default), capability-record, or surface."
    )

    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case report
        case capabilityRecord = "capability-record"
        case surface
    }

    @Argument(help: "Which schema: report | capability-record | surface.")
    var kind: Kind = .report

    func run() {
        switch kind {
        case .report: print(ReportSchema.json)
        case .capabilityRecord: print(CapabilitySchemas.recordJSON)
        case .surface: print(CapabilitySchemas.surfaceJSON)
        }
    }
}
