import ArgumentParser
import Foundation
import SwiftServeScan
import SwiftServeSource

/// `swiftserve scan-source <dir-or-file>` — Pillar 2, slice 3. Scans first-party source
/// for *dynamic* private-API access (string-based selectors, KVC keys, NSClassFromString,
/// dlopen/dlsym) that binary/symbol scanning structurally can't see — because the private
/// thing is a string at runtime, not a linked symbol. Runs locally; nothing leaves the machine.
struct ScanSource: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan-source",
        abstract: "Scan first-party source for dynamic private-API patterns the binary scan can't see."
    )

    @Argument(help: "A project directory (scanned recursively) or a single .swift/.m/.h file.")
    var path: String

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable summary.")
    var card = false

    @Option(name: .long, help: "Use a custom denylist JSON instead of the bundled seed.")
    var denylist: String?

    @Option(name: .long, help: "Exit 1 when findings reach this confidence: none|definite|any.")
    var failOn: FailOn = .none

    enum FailOn: String, ExpressibleByArgument, CaseIterable {
        case none, definite, any
    }

    func run() throws {
        // 1. Collect source files — the only I/O.
        let files: [SourceFile]
        do {
            files = try SourceCollector.collect(path)
        } catch let e as ScanError {
            try fail(e.message)
        }

        // 2. Parse → candidate sites (pure). Swift via the AST; ObjC best-effort via text.
        var sites: [CandidateSite] = []
        var swiftFiles = 0, objcFiles = 0
        for file in files {
            switch file.language {
            case .swift:
                swiftFiles += 1
                sites += SwiftSourceParser.candidates(in: file.contents, file: file.displayPath)
            case .objc:
                objcFiles += 1
                sites += ObjCHeuristicScanner.candidates(in: file.contents, file: file.displayPath)
            }
        }

        // 3. Load the denylist (data, not code) and apply the shared verdict.
        let list: Denylist
        do {
            list = try loadDenylist()
        } catch let e as ScanError {
            try fail(e.message)
        }
        let findings = SourceScanner.detect(sites, denylist: list)

        // 4. Honest framing in warnings — source is the false-positive-prone surface.
        var warnings: [String] = [
            "Source findings are leads: ‘possible’ means it looks private, not that Review will reject it.",
        ]
        if objcFiles > 0 {
            warnings.append("Objective-C (\(objcFiles) file\(objcFiles == 1 ? "" : "s")) scanned best-effort with text "
                + "patterns — no AST, so every ObjC finding is ‘possible’ only.")
        }
        if files.isEmpty {
            warnings.append("No .swift/.m/.h source found under \(path).")
        }
        if denylist == nil {
            warnings.append("Denylist is a seed proof-of-concept — not comprehensive.")
        }

        // 5. Assemble + output (JSON is the source of truth; the card renders from it).
        let report = SourceScanReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            target: .init(path: path, filesScanned: files.count, swiftFiles: swiftFiles, objcFiles: objcFiles),
            swiftee: BinaryVerdict.makeSource(findings: findings),
            summary: .init(findings: findings),
            findings: findings,
            warnings: warnings,
            denylist: .init(version: list.version, entryCount: list.entries.count))

        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderSourceCard(report))
        }

        // 6. CI gate — keyed on confidence, the axis that matters here. ‘possible’ never
        //    trips `--fail-on definite`, by design.
        switch failOn {
        case .none: break
        case .definite: if report.summary.definite > 0 { throw ExitCode(1) }
        case .any: if report.summary.findingCount > 0 { throw ExitCode(1) }
        }
    }

    // MARK: - Denylist loading (same bundled seed as scan-binary)

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

    private static func encodeJSON(_ report: SourceScanReport) throws -> String {
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

// MARK: - File collection (CLI side of the pure/impure boundary)

enum SourceLanguage { case swift, objc }

struct SourceFile {
    let displayPath: String   // relative to the scanned root — what the user sees
    let contents: String
    let language: SourceLanguage
}

/// Walks a directory (or accepts a single file) into the source files to parse. The
/// only filesystem I/O in the source pillar; parsing + matching are pure downstream.
enum SourceCollector {
    static func collect(_ input: String) throws -> [SourceFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input, isDirectory: &isDir) else {
            throw ScanError("no such file or directory: \(input)")
        }

        if !isDir.boolValue {
            guard let lang = language(forExtension: (input as NSString).pathExtension) else {
                throw ScanError("not a Swift/Objective-C source file: \(input)")
            }
            return [SourceFile(displayPath: (input as NSString).lastPathComponent,
                               contents: read(input), language: lang)]
        }

        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: input),
                                             includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var results: [SourceFile] = []
        for case let url as URL in enumerator {
            var isd: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isd)
            if isd.boolValue {
                if shouldSkipDir(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard let lang = language(forExtension: url.pathExtension) else { continue }
            results.append(SourceFile(displayPath: relativePath(of: url.path, under: input),
                                      contents: read(url.path), language: lang))
        }
        return results.sorted { $0.displayPath < $1.displayPath }
    }

    static func language(forExtension ext: String) -> SourceLanguage? {
        switch ext.lowercased() {
        case "swift": .swift
        case "m", "mm", "h": .objc
        default: nil
        }
    }

    /// Skip build output, dependency checkouts, and bundle internals — we scan
    /// *first-party source*, not vendored or generated trees.
    static func shouldSkipDir(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }   // .build, .git, .swiftpm, hidden
        if ["DerivedData", "Pods", "Carthage", "node_modules"].contains(name) { return true }
        for ext in [".xcframework", ".framework", ".app", ".xcodeproj", ".xcassets", ".bundle"]
        where name.hasSuffix(ext) { return true }
        return false
    }

    private static func relativePath(of full: String, under root: String) -> String {
        let r = root.hasSuffix("/") ? root : root + "/"
        return full.hasPrefix(r) ? String(full.dropFirst(r.count)) : full
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
