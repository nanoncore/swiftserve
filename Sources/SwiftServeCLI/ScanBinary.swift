import ArgumentParser
import Foundation
import SwiftServeScan

/// `swiftserve scan-binary <path>` — Pillar 2. Extracts symbols/selectors from a
/// Mach-O and reports references to known private Apple symbols. Runs locally;
/// nothing leaves the machine.
struct ScanBinary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan-binary",
        abstract: "Scan a compiled Mach-O (.app, .framework, .dylib, or raw binary) for private-API references."
    )

    @Argument(help: "Path to a Mach-O, .framework, .dylib, or .app bundle.")
    var path: String

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable summary.")
    var card = false

    @Option(name: .long, help: "Use a custom denylist JSON instead of the bundled seed.")
    var denylist: String?

    @Option(name: .long, help: "Exit 1 if any finding is at/above this severity: none|low|medium|high.")
    var failOn: FailOn = .none

    enum FailOn: String, ExpressibleByArgument, CaseIterable {
        case none, low, medium, high
        var threshold: Severity? {
            switch self {
            case .none: nil
            case .low: .low
            case .medium: .medium
            case .high: .high
            }
        }
    }

    func run() throws {
        // 1. Resolve the input to one or more Mach-O binaries.
        let resolved: Resolved
        do {
            resolved = try BinaryResolver.resolve(path)
        } catch let e as ScanError {
            try fail(e.message)
        }

        // 2. Extract symbols (the process-spawning boundary).
        var symbols: [ExtractedSymbol] = []
        var warnings = resolved.warnings
        var archSet = Set<String>()
        for target in resolved.targets {
            let arches = SymbolExtractor.architectures(of: target.path)
            archSet.formUnion(arches)
            if arches.count > 1 {
                warnings.append("Universal binary '\(target.displayName)' — scanned slices: \(arches.joined(separator: ", ")).")
            }
            symbols += SymbolExtractor.extract(binary: target.path, origin: target.origin, arches: arches)
        }
        if symbols.isEmpty {
            warnings.append("No symbols extracted — is Xcode command-line tools installed (xcrun nm/otool)?")
        }

        // 3. Load the denylist (data, not code).
        let list: Denylist
        do {
            list = try loadDenylist()
        } catch let e as ScanError {
            try fail(e.message)
        }
        if denylist == nil {
            warnings.append("Denylist is a seed proof-of-concept — not comprehensive.")
        }
        if resolved.targets.contains(where: { $0.origin.kind == .firstParty }) {
            warnings.append("Statically-linked dependencies are merged into the main binary and can't be attributed separately yet.")
        }

        // 4. Match (pure core) and assemble the report.
        let findings = BinaryScanner.detect(symbols, denylist: list)
        let report = BinaryReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            target: .init(path: path, kind: resolved.kind,
                          architectures: archSet.sorted(),
                          binariesScanned: resolved.targets.map(\.displayName)),
            swiftee: BinaryVerdict.make(findings: findings),
            summary: .init(findings: findings),
            findings: findings,
            warnings: warnings,
            denylist: .init(version: list.version, entryCount: list.entries.count))

        // 5. Output.
        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderBinaryCard(report))
        }

        // 6. CI gate.
        if let threshold = failOn.threshold, findings.contains(where: { $0.severity >= threshold }) {
            throw ExitCode(1)
        }
    }

    // MARK: - Denylist loading

    private func loadDenylist() throws -> Denylist {
        if let denylist {
            guard let data = FileManager.default.contents(atPath: denylist) else {
                throw ScanError("couldn't read denylist at \(denylist)")
            }
            return try Denylist.decode(from: data)
        }
        guard let url = Bundle.module.url(forResource: "denylist.seed", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "denylist.seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ScanError("bundled seed denylist is missing")
        }
        return try Denylist.decode(from: data)
    }

    // MARK: - Output helpers

    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
    }

    private static func encodeJSON(_ report: BinaryReport) throws -> String {
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

struct ScanError: Error { let message: String; init(_ m: String) { message = m } }
