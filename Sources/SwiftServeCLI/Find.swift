import ArgumentParser
import Foundation
import SwiftServeCapability

/// `swiftserve find --capability <id> --platform <p>` — the discovery
/// direction: what packages actually serve this, here? Ranked by verdict
/// strength × confidence; unsupported rows hidden unless asked for.
struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find packages that serve a capability on a platform, ranked."
    )

    @Option(name: .long, help: "Capability — taxonomy id, label, or alias.")
    var capability: String

    @Option(name: .long, help: "Platform: iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|linux.")
    var platform: Platform

    @Flag(name: .long, help: "Include packages that provably do NOT serve it here.")
    var all = false

    @Flag(name: .long, help: "Emit the canonical JSON report.")
    var json = false

    @Flag(name: .long, help: "Render the human-readable list.")
    var card = false

    @Option(name: .long, help: "Use a dataset JSON instead of the bundled one.")
    var dataset: String?

    func run() throws {
        let loaded: CapabilityDataset
        do {
            loaded = try DatasetLoader.load(override: dataset)
        } catch let e as ScanError {
            try fail(e.message)
        }

        let report: CapabilityQuery.FindReport
        do {
            report = try CapabilityQuery.find(dataset: loaded, capability: capability,
                                              platform: platform, includeUnsupported: all)
        } catch let e as CapabilityQuery.QueryError {
            try fail(e.description)
        }

        if wantsJSON {
            print(try DatasetLoader.encodeJSON(report))
        } else {
            print(renderFindCard(report))
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
