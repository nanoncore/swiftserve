import ArgumentParser
import Foundation
import SwiftServeCore
import SwiftServeScan

/// `swiftserve scan-deps <project-dir>` — Pillar 2, slice 2. Scans a project's
/// *dependency* binary artifacts (xcframeworks) for private-API references and
/// attributes each finding to the named dependency, split from first-party code.
struct ScanDeps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan-deps",
        abstract: "Scan a project's dependency binaries for private-API references, attributed per dependency."
    )

    @Argument(help: "Path to the project directory (Xcode or SwiftPM).")
    var path: String

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable summary.")
    var card = false

    @Option(name: .long, help: "Path to SourcePackages (override DerivedData auto-detection).")
    var sourcePackages: String?

    @Option(name: .long, help: "Path to a built .app (override) for the first-party scan.")
    var app: String?

    @Option(name: .long, help: "Use a custom denylist JSON instead of the bundled seed.")
    var denylist: String?

    @Option(name: .long, help: "Exit 1 if any finding is at/above this severity: none|low|medium|high.")
    var failOn: ScanBinary.FailOn = .none

    func run() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            try fail("not a project directory: \(path)")
        }

        var warnings: [String] = []
        var symbols: [ExtractedSymbol] = []
        var units: [ScanUnit] = []

        // 1. Package.resolved → identity → version.
        let pins = loadPins()
        if pins.isEmpty { warnings.append("No Package.resolved found — versions and attribution will be limited.") }
        let versionByIdentity = Dictionary(pins.map { ($0.identity.lowercased(), $0.resolvedVersion) },
                                           uniquingKeysWith: { a, _ in a })

        // 2. Locate SourcePackages (artifacts + checkouts).
        let spDir = resolveSourcePackages(&warnings)
        let artifactsDir = spDir.map { "\($0)/artifacts" }
        let checkoutNames = spDir.map { Set(listDir("\($0)/checkouts").map { $0.lowercased() }) } ?? []

        // 3. First-party: scan the built app's main executable if we can find one.
        if let appBin = resolveAppBinary(), let resolved = try? BinaryResolver.resolve(appBin),
           let target = resolved.targets.first {
            let origin = Origin(kind: .firstParty, artifact: target.displayName)
            symbols += SymbolExtractor.extract(binary: target.path, origin: origin,
                                               arches: SymbolExtractor.architectures(of: target.path))
            units.append(ScanUnit(kind: .firstParty, status: .scanned, artifacts: [target.displayName]))
        } else {
            units.append(ScanUnit(kind: .firstParty, status: .notBuilt))
            warnings.append("No built app found — your own code wasn't scanned. Build it, pass --app, or use `swiftserve scan-binary`.")
        }

        // 4. Dependency binary artifacts (xcframeworks).
        var scannedIdentities = Set<String>()
        if let artifactsDir, fm.fileExists(atPath: artifactsDir) {
            for entry in listDir(artifactsDir) where !isJunk(entry) {
                let idPath = "\(artifactsDir)/\(entry)"
                guard let xcf = XCFramework.findXCFramework(under: idPath) else { continue }
                guard let (binary, slice) = XCFramework.iOSDeviceBinary(at: xcf) else {
                    warnings.append("Couldn't resolve an iOS slice for \(entry); skipped.")
                    continue
                }
                let identity = entry                              // path component == package identity
                let version = versionByIdentity[identity.lowercased()] ?? nil
                let display = "\((xcf as NSString).lastPathComponent) (\(slice))"
                let origin = Origin(kind: .dependency, dependency: identity, version: version, artifact: display)
                symbols += SymbolExtractor.extract(binary: binary, origin: origin,
                                                   arches: SymbolExtractor.architectures(of: binary))
                units.append(ScanUnit(kind: .dependency, identity: identity, version: version,
                                      status: .scanned, artifacts: [display]))
                scannedIdentities.insert(identity.lowercased())
            }
        } else {
            warnings.append("No SourcePackages/artifacts found — pass --source-packages or build the project so binary deps are resolved.")
        }

        // 5. Resolved deps with no scanned artifact → sourceOnly (has a checkout) or notBuilt.
        for pin in pins where !scannedIdentities.contains(pin.identity.lowercased()) {
            let status: ScanStatus = checkoutNames.contains(pin.identity.lowercased()) ? .sourceOnly : .notBuilt
            units.append(ScanUnit(kind: .dependency, identity: pin.identity,
                                  version: pin.resolvedVersion, status: status))
        }
        if pins.contains(where: { checkoutNames.contains($0.identity.lowercased()) && !scannedIdentities.contains($0.identity.lowercased()) }) {
            warnings.append("Source-only dependencies aren't separately scanned here — their private-API use surfaces via the app-binary scan (or the future source scanner).")
        }

        // 6. Match (pure) + attribute (origins already set) + roll up.
        let list = try loadDenylist(&warnings)
        let findings = BinaryScanner.detect(symbols, denylist: list)
        let rollups = DependencyRollup.build(units: units, findings: findings)

        let report = DependencyScanReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            target: .init(path: path, project: projectName(),
                          sourcePackages: spDir, appBinary: resolveAppBinary()),
            swiftee: BinaryVerdict.makeDeps(findings: findings),
            summary: .init(findings: findings),
            dependencies: rollups,
            findings: findings,
            warnings: warnings,
            denylist: .init(version: list.version, entryCount: list.entries.count))

        if wantsJSON {
            print(try Self.encodeJSON(report))
        } else {
            print(renderDependencyCard(report))
        }

        if let threshold = failOn.threshold, findings.contains(where: { $0.severity >= threshold }) {
            throw ExitCode(1)
        }
    }

    // MARK: - Locate

    private func loadPins() -> [Pin] {
        let candidates = [
            firstMatch("\(path)", suffix: ".xcodeproj").map { "\(path)/\($0)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" },
            firstMatch("\(path)", suffix: ".xcworkspace").map { "\(path)/\($0)/xcshareddata/swiftpm/Package.resolved" },
            "\(path)/Package.resolved",
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            if let data = FileManager.default.contents(atPath: c),
               let pins = try? PackageResolvedParser().parse(data) {
                return pins
            }
        }
        return []
    }

    private func resolveSourcePackages(_ warnings: inout [String]) -> String? {
        if let sourcePackages { return sourcePackages }
        // SwiftPM project
        let dotBuild = "\(path)/.build"
        if FileManager.default.fileExists(atPath: "\(dotBuild)/artifacts") { return dotBuild }
        // Xcode project → newest DerivedData/<Project>-*/SourcePackages
        guard let proj = projectName() else { return nil }
        let ddRoot = ("~/Library/Developer/Xcode/DerivedData" as NSString).expandingTildeInPath
        let matches = listDir(ddRoot)
            .filter { $0.hasPrefix("\(proj)-") }
            .map { "\(ddRoot)/\($0)/SourcePackages" }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted { mtime($0) > mtime($1) }
        if matches.count > 1 { warnings.append("Multiple DerivedData dirs for \(proj); used the most recent. Pass --source-packages to pin it.") }
        return matches.first
    }

    private func resolveAppBinary() -> String? {
        if let app {
            return (try? BinaryResolver.resolve(app))?.targets.first?.path
        }
        // Look for a built .app under <proj>/build/Debug-*.
        let buildDir = "\(path)/build"
        for sub in listDir(buildDir) where sub.hasPrefix("Debug-") {
            let dir = "\(buildDir)/\(sub)"
            if let appName = firstMatch(dir, suffix: ".app"),
               let bin = (try? BinaryResolver.resolve("\(dir)/\(appName)"))?.targets.first?.path {
                return bin
            }
        }
        return nil
    }

    private func projectName() -> String? {
        firstMatch(path, suffix: ".xcodeproj").map { String($0.dropLast(".xcodeproj".count)) }
    }

    // MARK: - Helpers

    private func listDir(_ p: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
    }
    private func firstMatch(_ dir: String, suffix: String) -> String? {
        listDir(dir).first { $0.hasSuffix(suffix) }
    }
    private func mtime(_ p: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
    private func isJunk(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name == "extract" || name.hasPrefix("._")
    }

    private func loadDenylist(_ warnings: inout [String]) throws -> Denylist {
        if let denylist {
            guard let data = FileManager.default.contents(atPath: denylist) else { throw ScanError("couldn't read denylist at \(denylist)") }
            return try Denylist.decode(from: data)
        }
        warnings.append("Denylist is a seed proof-of-concept — not comprehensive.")
        guard let url = Bundle.module.url(forResource: "denylist.seed", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "denylist.seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw ScanError("bundled seed denylist is missing") }
        return try Denylist.decode(from: data)
    }

    private var wantsJSON: Bool {
        if json { return true }
        if card { return false }
        return !Terminal.isInteractive
    }

    private static func encodeJSON(_ report: DependencyScanReport) throws -> String {
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
