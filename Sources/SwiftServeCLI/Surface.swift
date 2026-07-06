import ArgumentParser
import Foundation
import SwiftServeCapability
import SwiftServeSurface

/// `swiftserve surface <dir-or-file>` — the deterministic layer of capability
/// search. Extracts a package checkout's public API surface × platform
/// conditionals (`#if`, `@available`) into canonical JSON. Parsing only:
/// nothing is compiled, nothing is guessed, nothing leaves the machine.
struct Surface: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "surface",
        abstract: "Extract a package's public API surface × platform guards to canonical JSON."
    )

    @Argument(help: "A package checkout directory (walked recursively) or a single .swift file.")
    var path: String

    @Flag(name: .long, help: "Emit the canonical surface JSON.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable summary.")
    var card = false

    @Option(name: .long, help: "Package name for provenance (defaults to the directory name).")
    var name: String?

    @Option(name: .long, help: "Write the surface JSON to this file instead of stdout.")
    var out: String?

    func run() throws {
        let modules: ModulePlatformTable
        do {
            modules = try Self.loadModuleTable()
        } catch let e as ScanError {
            try fail(e.message)
        }

        let resolvedName = name ?? URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        let surface: PackageSurface
        do {
            surface = try SurfaceBuilder.build(
                path: path,
                provenance: PackageProvenance(canonicalURL: nil, name: resolvedName, tag: nil, commit: nil),
                modules: modules)
        } catch let e as ScanError {
            try fail(e.message)
        }

        let encoded = try SurfaceBuilder.encodeJSON(surface)
        if let out {
            do {
                try Data((encoded + "\n").utf8).write(to: URL(fileURLWithPath: out))
            } catch {
                try fail("couldn't write \(out): \(error.localizedDescription)")
            }
            if !wantsJSON { print(renderSurfaceCard(surface, writtenTo: out)) }
        } else if wantsJSON {
            print(encoded)
        } else {
            print(renderSurfaceCard(surface, writtenTo: nil))
        }
    }

    // MARK: - Module table (data, not code — same pattern as the denylist)

    static func loadModuleTable() throws -> ModulePlatformTable {
        guard let url = Bundle.module.url(forResource: "module-platforms", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "module-platforms", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ScanError("bundled module-platforms table is missing")
        }
        return try ModulePlatformTable.decode(from: data)
    }

    // MARK: - Output

    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
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

/// The shared extraction driver: checkout directory in, resolved
/// `PackageSurface` out. Used by `surface` (local dirs) and `index extract`
/// (corpus checkouts) so both emit identical JSON for identical input.
enum SurfaceBuilder {
    static func build(path: String, provenance: PackageProvenance,
                      modules: ModulePlatformTable) throws -> PackageSurface {
        let files = try SurfaceFileCollector.collect(path)

        var decls: [SurfaceDecl] = []
        var swiftFiles = 0, objcFiles = 0, objcHeadersParsed = 0, parseFailures = 0
        for file in files {
            switch file.language {
            case .swift:
                swiftFiles += 1
                if file.contents.isEmpty { parseFailures += 1; continue }
                decls += SurfaceExtractor.decls(in: file.contents, file: file.displayPath)
            case .objc:
                // Public headers ARE the ObjC surface — the header scanner
                // turns them into decls. Implementations (.m) and private
                // headers stay counted as the honest blind spot.
                let isHeader = file.displayPath.hasSuffix(".h")
                let isPrivate = file.displayPath.range(of: "private", options: .caseInsensitive) != nil
                if isHeader && !isPrivate && !file.contents.isEmpty {
                    decls += ObjCHeaderParser.decls(in: file.contents, file: file.displayPath)
                    objcHeadersParsed += 1
                } else {
                    objcFiles += 1
                }
            }
        }

        // The resolver pass: every decl gets its per-platform truth filled in.
        decls = decls.map { decl in
            decl.resolving(PlatformResolver.resolve(
                condition: decl.condition, availability: decl.availability, modules: modules))
        }

        // Manifest platforms — version floors, never exclusions.
        var manifestPlatforms: [ManifestPlatform] = []
        var manifestUnparsed = false
        var hasBinaryTargets = false
        let manifestPath = URL(fileURLWithPath: path).standardizedFileURL.appendingPathComponent("Package.swift").path
        if let manifest = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            if let parsed = ManifestPlatforms.extract(from: manifest) {
                manifestPlatforms = parsed
            } else {
                manifestUnparsed = true
            }
            hasBinaryTargets = ManifestPlatforms.hasBinaryTargets(in: manifest)
        }

        return PackageSurface(
            package: provenance,
            manifestPlatforms: manifestPlatforms,
            decls: decls,
            stats: SurfaceStats(swiftFiles: swiftFiles, objcFiles: objcFiles,
                                objcHeadersParsed: objcHeadersParsed, declCount: decls.count,
                                parseFailures: parseFailures, manifestUnparsed: manifestUnparsed,
                                hasBinaryTargets: hasBinaryTargets))
    }

    static func encodeJSON(_ surface: PackageSurface) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(surface), as: UTF8.self)
    }
}

/// The compact terminal view — counts and the guard picture, rendered from the
/// same data the JSON carries.
func renderSurfaceCard(_ surface: PackageSurface, writtenTo out: String?) -> String {
    let s = surface.stats
    let guarded = surface.decls.filter { $0.condition != nil }.count
    let availabilityFenced = surface.decls.filter { d in d.availability.contains(where: \.unavailable) }.count

    var lines: [String] = []
    lines.append(Style.bold("🍦 \(surface.package.name) — public surface"))
    lines.append("   \(s.declCount) public declarations across \(s.swiftFiles) Swift file\(s.swiftFiles == 1 ? "" : "s")")
    if guarded > 0 {
        lines.append("   \(Style.orange("\(guarded)")) under #if platform guards — the capability signal")
    }
    if availabilityFenced > 0 {
        lines.append("   \(availabilityFenced) marked unavailable on at least one platform")
    }
    if s.objcHeadersParsed > 0 {
        lines.append(Style.dim("   \(s.objcHeadersParsed) Objective-C header\(s.objcHeadersParsed == 1 ? "" : "s") parsed into the surface"))
    }
    if s.objcFiles > 0 {
        lines.append(Style.dim("   \(s.objcFiles) Objective-C file\(s.objcFiles == 1 ? "" : "s") not parsed (implementations + private headers) — surface may be incomplete"))
    }
    if s.parseFailures > 0 {
        lines.append(Style.dim("   \(s.parseFailures) file\(s.parseFailures == 1 ? "" : "s") unreadable"))
    }
    if let out {
        lines.append(Style.dim("   surface JSON → \(out)"))
    }
    return lines.joined(separator: "\n")
}

/// Walks a checkout into Swift sources (parsed) + ObjC sources (counted).
/// Skips test/example trees and build internals — capability truth is about
/// the shipped surface, not fixtures.
enum SurfaceFileCollector {
    static func collect(_ input: String) throws -> [SourceFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input, isDirectory: &isDir) else {
            throw ScanError("no such file or directory: \(input)")
        }

        if !isDir.boolValue {
            guard let lang = SourceCollector.language(forExtension: (input as NSString).pathExtension) else {
                throw ScanError("not a Swift/Objective-C source file: \(input)")
            }
            return [SourceFile(displayPath: (input as NSString).lastPathComponent,
                               contents: (try? String(contentsOfFile: input, encoding: .utf8)) ?? "",
                               language: lang)]
        }

        // Anchor paths to an absolute root: displayPath must stay repo-relative
        // regardless of how the argument was spelled — these paths become
        // evidence anchors and GitHub permalinks downstream. Both sides go
        // through the same symlink normalization (which on macOS also strips
        // /private) or an enumerator path under /private/tmp would never
        // match a root spelled /tmp.
        let root = URL(fileURLWithPath: input).resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                             includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var results: [SourceFile] = []
        for case let url as URL in enumerator {
            var isd: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isd)
            if isd.boolValue {
                if shouldSkipDir(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard let lang = SourceCollector.language(forExtension: url.pathExtension) else { continue }
            results.append(SourceFile(displayPath: relativePath(of: url.resolvingSymlinksInPath().path, under: root),
                                      contents: (try? String(contentsOfFile: url.path, encoding: .utf8)) ?? "",
                                      language: lang))
        }
        return results.sorted { $0.displayPath < $1.displayPath }
    }

    /// Everything SourceCollector skips, plus the trees that aren't shipped
    /// surface: tests, examples, docs, benchmarks.
    static func shouldSkipDir(_ name: String) -> Bool {
        if SourceCollector.shouldSkipDir(name) { return true }
        return ["Tests", "Test", "Example", "Examples", "Sample", "Samples",
                "Benchmarks", "docs", "Docs", "Documentation"].contains(name)
    }

    private static func relativePath(of full: String, under root: String) -> String {
        let r = root.hasSuffix("/") ? root : root + "/"
        return full.hasPrefix(r) ? String(full.dropFirst(r.count)) : full
    }
}
