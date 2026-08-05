import ArgumentParser
import Foundation
import SwiftServeCore
import SwiftServeCapability
import SwiftServeReceipt

/// SwiftServe's terminal/CI/agent front door. Same `SwiftServeCore`, same canonical
/// JSON as the web `POST /analyze` — the human card is rendered from that JSON.
@main
struct SwiftServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftserve",
        abstract: "Review Swift dependency changes, capability truth, health, and private APIs.",
        discussion: """
        OUTPUT
          Human output on an interactive terminal; canonical JSON when piped or
          redirected. `diff --markdown` writes a GitHub Step Summary receipt.

        EXIT CODES (for scripts and agents)
          0  operation completed and the configured gate passed
          1  operation completed but its policy/gate failed
          2  malformed input or infrastructure prevented a trustworthy result

        AGENTS
          `swiftserve scan --json` emits the canonical report on stdout (and a
          {"error": …} envelope on stderr if it fails). `swiftserve diff --json`
          emits a versioned Upgrade Receipt; `schema upgrade-receipt` documents it.

        ENVIRONMENT
          GITHUB_TOKEN     enable live GitHub enrichment (else file-only)
          NO_COLOR         disable ANSI color
          CLICOLOR_FORCE   force ANSI color even when not a TTY
        """,
        version: "0.7.0",
        subcommands: [Scan.self, Diff.self, ScanBinary.self, ScanDeps.self, ScanSource.self, BuildTiming.self, BuildCost.self, Surface.self, Index.self, CapabilityCheck.self, Find.self, Schema.self],
        defaultSubcommand: Scan.self
    )

    /// ArgumentParser normally exits with EX_USAGE before a subcommand can
    /// enforce SwiftServe's public error contract. Intercept parse failures for
    /// `diff` so malformed invocations use exit 2 and the JSON stderr envelope.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command: ParsableCommand
        do {
            command = try parseAsRoot(arguments)
        } catch {
            handleParsingError(error, arguments: arguments)
        }

        do {
            var command = command
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    private static func handleParsingError(_ error: Error, arguments: [String]) -> Never {
        guard arguments.first == "diff", exitCode(for: error).rawValue != 0 else {
            exit(withError: error)
        }

        let wantsJSON = arguments.contains("--json")
            || (!arguments.contains("--markdown") && !arguments.contains("--card") && !Terminal.isInteractive)
        let message = message(for: error)
        let line: String
        if wantsJSON,
           let data = try? JSONEncoder().encode(["error": message]),
           let encoded = String(data: data, encoding: .utf8) {
            line = encoded
        } else {
            line = "Error: \(message)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        exit(withError: ExitCode(2))
    }
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
        abstract: "Print a JSON Schema: report (default), upgrade-receipt, capability-record, or surface."
    )

    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case report
        case upgradeReceipt = "upgrade-receipt"
        case capabilityRecord = "capability-record"
        case surface
    }

    @Argument(help: "Which schema: report | upgrade-receipt | capability-record | surface.")
    var kind: Kind = .report

    func run() {
        switch kind {
        case .report: print(ReportSchema.json)
        case .upgradeReceipt: print(UpgradeReceiptSchema.json)
        case .capabilityRecord: print(CapabilitySchemas.recordJSON)
        case .surface: print(CapabilitySchemas.surfaceJSON)
        }
    }
}
