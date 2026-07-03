import ArgumentParser
import Foundation
import SwiftServeCapability
import SwiftServeSite

/// `swift run SwiftServeSiteGen` — stamps the capability site into Public/.
/// Repo-internal tooling; the output is what gets served (locally by the
/// Hummingbird server, publicly by GitHub Pages at launch).
@main
struct SiteGen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sitegen",
        abstract: "Generate the SwiftServe capability site from validated records."
    )

    @Option(name: .long, help: "Root of validated record files (domain subdirs are scanned).")
    var records = "data/records"

    @Option(name: .long, help: "Directory of per-domain taxonomy files (merged).")
    var taxonomy = "data/taxonomy"

    @Option(name: .long, help: "Output directory (the web root).")
    var out = "Public"

    @Option(name: .long, help: "Href prefix for a subpath deploy (e.g. /swiftserve on a Pages project site).")
    var basePath = ""

    @Option(name: .long, help: "Optional build stamp shown in the footer (omitted = byte-identical regeneration).")
    var stamp: String?

    @Option(name: .long, help: "Path to the canonical Claude Code skill, emitted as /skill.md.")
    var skill = ".claude/skills/swiftserve/SKILL.md"

    func run() throws {
        let fm = FileManager.default

        // Merge every domain's taxonomy (audio.json + networking.json + …).
        let taxonomyFiles = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: taxonomy),
                                                          includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
        guard !taxonomyFiles.isEmpty else { throw ValidationError("no taxonomy files in \(taxonomy)") }
        let merged = try Taxonomy.merged(taxonomyFiles.map { file in
            guard let data = fm.contents(atPath: file.path) else {
                throw ValidationError("couldn't read \(file.path)")
            }
            return try Taxonomy.decode(from: data)
        })

        // Records: flat files plus one level of domain subdirectories.
        var recordFiles: [URL] = []
        let root = URL(fileURLWithPath: records)
        for entry in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []) {
            if entry.pathExtension == "json" {
                recordFiles.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                recordFiles += ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }
            }
        }
        var allRecords: [CapabilityRecord] = []
        let decoder = JSONDecoder()
        for file in recordFiles.sorted(by: { $0.path < $1.path }) {
            guard let data = fm.contents(atPath: file.path) else { continue }
            if let array = try? decoder.decode([CapabilityRecord].self, from: data) {
                allRecords += array
            } else {
                allRecords.append(try decoder.decode(CapabilityRecord.self, from: data))
            }
        }
        allRecords.sort { ($0.package.canonicalURL, $0.capability.id) < ($1.package.canonicalURL, $1.capability.id) }

        // Version the static assets by content (FNV-1a) so cached copies are
        // never served after a change. Content-derived — same bytes, same URL.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for asset in ["styles.css", "site.js", "xr-entry.js", "xr.js"] {
            for byte in fm.contents(atPath: "\(out)/\(asset)") ?? Data() {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }

        let dataset = CapabilityDataset(taxonomy: merged, records: allRecords)
        let site = Site(model: SiteModel(dataset: dataset), basePath: basePath, stamp: stamp,
                        assetVersion: String(hash, radix: 36))
        let skillMarkdown = fm.contents(atPath: skill).flatMap { String(data: $0, encoding: .utf8) }
        let written = try SiteGenerator.write(site: site, to: URL(fileURLWithPath: out),
                                              skillMarkdown: skillMarkdown)

        print("🍦 site generated — \(written.count) files → \(out)/")
        print("   \(allRecords.count) records · \(site.model.packages.count) packages · \(site.model.capabilities.count) capabilities")
        print("   browse locally: swift run SwiftServeServer  →  http://127.0.0.1:8080")
    }
}
