import ArgumentParser
import Foundation
import SwiftServeCapability
import SwiftServeCore

/// `swiftserve capability-check <package> --capability <id> --platform <p>` —
/// the north-star question: does this package actually serve this feature on
/// this platform? Answered from validated, evidence-anchored records; every
/// verdict carries the receipt (the exact source line, permalinked).
struct CapabilityCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capability-check",
        abstract: "Does a package actually serve a capability on a platform? Verdict + evidence."
    )

    @Argument(help: "Package — URL, owner/repo, name, or alias (e.g. ‘livekit’).")
    var package: String

    @Option(name: .long, help: "Capability — taxonomy id, label, or alias (e.g. ‘noise cancellation’).")
    var capability: String

    @Option(name: .long, help: "Platform: iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|linux.")
    var platform: Platform

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable card.")
    var card = false

    @Option(name: .long, help: "Use a dataset JSON instead of the bundled one (dev: `index assemble` output).")
    var dataset: String?

    @Option(name: .long, help: "Exit 1 unless the verdict matches (CI gate / regression check).")
    var expect: ClaimStatus?

    func run() throws {
        let loaded: CapabilityDataset
        do {
            loaded = try DatasetLoader.load(override: dataset)
        } catch let e as ScanError {
            try fail(e.message)
        }

        let report: CheckReport
        do {
            report = try CapabilityQuery.check(dataset: loaded, package: package,
                                               capability: capability, platform: platform)
        } catch let e as CapabilityQuery.QueryError {
            try fail(e.description)
        }

        if wantsJSON {
            print(try DatasetLoader.encodeJSON(report))
        } else {
            print(renderCapabilityCard(report))
        }

        if let expect, report.verdict.status != expect {
            throw ExitCode(1)
        }
    }

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

extension Platform: ExpressibleByArgument {
    public init?(argument: String) {
        let aliases: [String: Platform] = [
            "ios": .iOS, "macos": .macOS, "watchos": .watchOS, "tvos": .tvOS,
            "visionos": .visionOS, "maccatalyst": .macCatalyst, "catalyst": .macCatalyst,
            "linux": .linux, "osx": .macOS,
        ]
        guard let platform = aliases[argument.lowercased()] else { return nil }
        self = platform
    }

    public static var allValueStrings: [String] { Platform.allCases.map(\.rawValue) }
}

extension ClaimStatus: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

/// Loads the query dataset: `--dataset` override, else the bundled snapshot
/// from `index assemble` (same double-lookup as every bundled resource).
enum DatasetLoader {
    static func load(override: String?) throws -> CapabilityDataset {
        if let override {
            guard let data = FileManager.default.contents(atPath: override) else {
                throw ScanError("couldn't read dataset at \(override)")
            }
            return try CapabilityDataset.decode(from: data)
        }
        guard let url = Bundle.module.url(forResource: "capability-dataset", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "capability-dataset", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ScanError("no bundled capability dataset — run `swiftserve index assemble` and rebuild, or pass --dataset")
        }
        return try CapabilityDataset.decode(from: data)
    }

    static func encodeJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
