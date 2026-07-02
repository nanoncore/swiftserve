import Foundation
import SwiftServeCapability

/// Stamps the whole site into the output directory. Deterministic: sorted
/// iteration everywhere, no wall-clock unless a stamp is passed — re-running
/// on the same dataset produces zero diff.
public enum SiteGenerator {

    public struct Output: Sendable, Equatable {
        public let path: String     // relative to the out dir
        public let bytes: Data
    }

    /// Pure planning: everything to write, as (path, bytes) pairs.
    /// `skillMarkdown` is the canonical Claude Code skill, served at /skill.md
    /// so agents can install it with one curl.
    public static func plan(site: Site, skillMarkdown: String? = nil) throws -> [Output] {
        var outputs: [Output] = []
        func add(_ path: String, _ html: String) {
            outputs.append(Output(path: path, bytes: Data(html.utf8)))
        }
        func add(_ path: String, _ data: Data) {
            outputs.append(Output(path: path, bytes: data))
        }

        add("index.html", HomePage.render(site: site))
        add("menu/index.html", MenuPage.render(site: site))
        add("about/index.html", AboutPage.render(site: site))
        add("agents/index.html", AgentsPage.render(site: site))
        add("404.html", NotFoundPage.render(site: site))

        for view in site.model.capabilities {
            add("can/\(view.capability.id)/index.html", CapabilityPage.render(view, site: site))
        }
        for package in site.model.packages {
            add("package/\(package.slug)/index.html", PackagePage.render(package, site: site))
        }

        add("api/index.json", try ApiOutput.rootIndex(site: site))
        add("api/taxonomy.json", try ApiOutput.encoder.encode(site.model.dataset.taxonomy))
        add("api/packages/index.json", try ApiOutput.packagesIndex(site: site))
        for package in site.model.packages {
            add("api/packages/\(package.slug).json", try ApiOutput.packageJSON(package))
        }
        for view in site.model.capabilities where !view.rows.isEmpty {
            add("api/capabilities/\(view.capability.id).json", try ApiOutput.capabilityJSON(view, site: site))
        }
        add("api/search-index.json", try ApiOutput.searchIndex(site: site))
        add("api/schemas/capability-record-v1.json", Data(CapabilitySchemas.recordJSON.utf8))
        add("api/schemas/package-surface-v1.json", Data(CapabilitySchemas.surfaceJSON.utf8))

        for package in site.model.packages {
            add("badge/\(package.slug)/verified.svg", Data(BadgeSVG.verified(package: package).utf8))
            add("badge/\(package.slug)/matrix.svg", Data(BadgeSVG.matrix(package: package).utf8))
            for record in package.records {
                add("badge/\(package.slug)/\(record.capability.id).svg", Data(BadgeSVG.strip(record: record).utf8))
            }
        }

        add("llms.txt", Data(llmsTxt(site: site).utf8))
        add("get/index.html", GetPage.render(site: site))
        if let skillMarkdown {
            add("skill.md", Data(skillMarkdown.utf8))
        }

        return outputs.sorted { $0.path < $1.path }
    }

    /// Write the plan to disk. Returns the paths written.
    @discardableResult
    public static func write(site: Site, to outDir: URL, skillMarkdown: String? = nil) throws -> [String] {
        let outputs = try plan(site: site, skillMarkdown: skillMarkdown)
        let fm = FileManager.default
        for output in outputs {
            let url = outDir.appendingPathComponent(output.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.bytes.write(to: url)
        }
        return outputs.map(\.path)
    }

    private static func llmsTxt(site: Site) -> String {
        """
        # SwiftServe — capability truth for Swift packages

        > What Swift packages actually serve, per Apple platform, derived from source
        > at pinned versions, with evidence permalinks. Static JSON API, stable schema.

        - Start here: \(site.basePath)/api/index.json
        - Capability pivot (the question agents ask): \(site.basePath)/api/capabilities/{id}.json
        - How verdicts are derived: \(site.basePath)/about/
        - For agents (CLI, skill, examples): \(site.basePath)/agents/
        - Install (plugin, skill, CLI): \(site.basePath)/get/
        - The Claude Code skill, ready to save: \(site.basePath)/skill.md
        """
    }
}
