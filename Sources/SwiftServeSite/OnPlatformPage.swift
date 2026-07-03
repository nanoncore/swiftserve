import Foundation
import SwiftServeCapability

/// /on/<platform> — the platform pivot. One URL that answers "what is the
/// state of <platform> in the Swift ecosystem?": headline counts, what the OS
/// already covers, per-capability coverage, the proven fences with their
/// compiler receipts, and the unknowns we refuse to guess. Designed
/// headset-first — big type, generous targets — and renders fully without
/// JavaScript; every link is a plain <a>.
public enum OnPlatformPage {

    /// "/on/visionos/" — the canonical page path for a platform pivot.
    public static func path(for platform: Platform) -> String {
        "/on/\(platform.rawValue.lowercased())/"
    }

    public static func render(_ view: OnPlatformView, site: Site) -> String {
        let platformLabel = PlatformDisplay.label(view.platform)

        // The fence yard is the visionOS demo — the immersive layer renders
        // that platform's feed, so only the visionOS pivot carries the slot
        // and pays the one small script tag. Other pivots stay flat.
        let immersive = view.platform == .visionOS

        let main = """
            <section class="page-head on-head">
              <p class="crumb"><a href="\(site.href("/menu/"))">Menu</a> / on \(platformLabel)</p>
              <h1>The state of <em>\(platformLabel)</em></h1>
              <p class="on-tagline">What the Swift ecosystem actually serves on \(platformLabel) —
              every count below is derived from the records, and every verdict carries its receipt.</p>
            </section>
        \(statTiles(view))
        \(immersive ? #"    <div class="xr-slot" data-xr hidden></div>"# : "")
        \(builtInSection(view, site: site, platformLabel: platformLabel))
        \(capabilitiesSection(view, site: site, platformLabel: platformLabel))
        \(fenceSection(view, site: site, platformLabel: platformLabel))
        \(unknownsSection(view, site: site))
            <section class="on-section on-feed">
              <p>This whole page, one fetch:
              <a href="\(site.href(apiPath(for: view.platform)))"><code>\(apiPath(for: view.platform))</code></a>
              — counts, coverage, fences, and receipts as static JSON.</p>
            </section>
        """
        // xr-entry.js is pure progressive enhancement: it feature-detects
        // immersive support and stays silent everywhere else.
        return site.page(title: "The state of \(platformLabel)",
                         description: "What the Swift ecosystem actually serves on \(platformLabel): \(view.supported) supported verdicts, \(view.unsupported) proven fences with compiler receipts, \(view.unknown) honest unknowns.",
                         path: path(for: view.platform), wide: true,
                         extraHead: immersive ? site.script("/xr-entry.js") : "", main: main)
    }

    /// "/api/on/visionos.json" — the page's one-fetch data feed.
    public static func apiPath(for platform: Platform) -> String {
        "/api/on/\(platform.rawValue.lowercased()).json"
    }

    // MARK: - Sections

    private static func statTiles(_ view: OnPlatformView) -> String {
        var tiles = """
              <div class="stat-tile stat-good"><span class="stat-num">\(view.supported)</span><span class="stat-label">serve it</span></div>
        """
        if view.conditional > 0 {
            tiles += """

              <div class="stat-tile stat-warn"><span class="stat-num">\(view.conditional)</span><span class="stat-label">with conditions</span></div>
            """
        }
        tiles += """

              <div class="stat-tile stat-low"><span class="stat-num">\(view.unsupported)</span><span class="stat-label">fenced out — proven</span></div>
              <div class="stat-tile stat-unknown"><span class="stat-num">\(view.unknown)</span><span class="stat-label">honest unknowns</span></div>
        """
        return """
            <section class="stat-tiles" aria-label="\(PlatformDisplay.label(view.platform)) verdict counts">
        \(tiles)
            </section>
            <p class="stat-caption">across \(view.recordCount) records · \(view.packageCount) packages — counted at generation time, never by hand</p>
        """
    }

    private static func builtInSection(_ view: OnPlatformView, site: Site,
                                       platformLabel: String) -> String {
        guard !view.builtIn.isEmpty else { return "" }
        let recordTotal = view.builtIn.map(\.coverage.count).reduce(0, +)
        let cards = view.builtIn.map { framework -> String in
            let items = framework.coverage.map { entry -> String in
                let floor = entry.floor.map { " <span class=\"floor\">\(Html.escape($0))</span>" } ?? ""
                return """
                    <li><a href="\(site.href("/can/\(entry.capability.id)/?on=\(view.platform.rawValue)"))">\(Html.escape(entry.capability.label))</a>\(floor)</li>
                """
            }.joined(separator: "\n")
            return """
                  <article class="builtin-card">
                    <h3>\(CapabilityPage.appleMark) <a href="\(site.href("/package/\(framework.slug)/"))">\(Html.escape(framework.name))</a> <span class="pill pill-builtin">built in</span></h3>
                    <p class="provenance">as of \(Html.escape(framework.version))</p>
                    <ul class="builtin-caps">
                \(items)
                    </ul>
                  </article>
            """
        }.joined(separator: "\n")
        return """
            <section class="on-section">
              <h2>Built into the OS</h2>
              <p class="section-intro">\(view.builtIn.count) Apple frameworks already cover
              \(recordTotal) capabilities on \(platformLabel) — nothing to add to your
              Package.swift. Floors come from Apple's own symbol graphs.</p>
              <div class="builtin-grid">
        \(cards)
              </div>
            </section>
        """
    }

    private static func capabilitiesSection(_ view: OnPlatformView, site: Site,
                                            platformLabel: String) -> String {
        guard !view.capabilities.isEmpty else { return "" }
        // Group by category prefix, same shape as the menu.
        var groups: [String: [OnPlatformView.CapabilityCoverage]] = [:]
        for entry in view.capabilities {
            let prefix = entry.capability.id.split(separator: ".").first.map(String.init) ?? "other"
            groups[prefix, default: []].append(entry)
        }
        let sections = groups.keys.sorted().map { key -> String in
            let items = groups[key]!.map { entry -> String in
                let count: String
                if entry.packages == 0 {
                    count = "<span class=\"on-cap-count muted\">no packages needed</span>"
                } else {
                    count = "<span class=\"on-cap-count\">\(entry.supported) of \(entry.packages) package\(entry.packages == 1 ? "" : "s")</span>"
                }
                let osMark = entry.builtInCovers
                    ? " <span class=\"os-covers\" title=\"an OS framework serves this on \(platformLabel)\">\(CapabilityPage.appleMark) in the OS</span>"
                    : ""
                return """
                    <li>
                      <a href="\(site.href("/can/\(entry.capability.id)/?on=\(view.platform.rawValue)"))">
                        <span class="menu-cap">\(Html.escape(entry.capability.label))</span>
                        \(count)\(osMark)
                      </a>
                    </li>
                """
            }.joined(separator: "\n")
            return """
              <section class="menu-group">
                <h3>\(CategoryView.label(for: key))</h3>
                <ul class="menu-list on-cap-list">
            \(items)
                </ul>
              </section>
            """
        }.joined(separator: "\n")
        return """
            <section class="on-section">
              <h2>Packages by capability</h2>
              <p class="section-intro">How many verified packages serve each capability on
              \(platformLabel). Every link opens the truth table focused on \(platformLabel) —
              near-misses included.</p>
        \(sections)
            </section>
        """
    }

    private static func fenceSection(_ view: OnPlatformView, site: Site,
                                     platformLabel: String) -> String {
        guard !view.fenced.isEmpty else { return "" }
        let fenceCount = view.fenced.map(\.fences.count).reduce(0, +)
        let cards = view.fenced.map { package -> String in
            let items = package.fences.map { fence -> String in
                let pills = fence.worksOn.map {
                    "<span>\(PlatformDisplay.label($0))</span>"
                }.joined()
                let worksOn = fence.worksOn.isEmpty ? "" : """

                      <span class="works-on">serves it on <span class="serves-pills">\(pills)</span></span>
                """
                return """
                    <div class="fence-item">
                      <p class="fence-cap"><a href="\(site.href("/can/\(fence.capability.id)/?on=\(view.platform.rawValue)"))">\(Html.escape(fence.capability.label))</a>\(worksOn)</p>
                      <p class="fence-receipt"><code>\(Html.escape(fence.receipt))</code></p>
                    </div>
                """
            }.joined(separator: "\n")
            return """
                  <article class="fence-card">
                    <h3><a href="\(site.href("/package/\(package.slug)/"))">\(Html.escape(package.name))</a> <span class="provenance">as of \(Html.escape(package.version))</span></h3>
                \(items)
                  </article>
            """
        }.joined(separator: "\n")
        return """
            <section class="on-section">
              <h2>The fence list</h2>
              <p class="section-intro">\(fenceCount) verdict\(fenceCount == 1 ? "" : "s") across
              \(view.fenced.count) package\(view.fenced.count == 1 ? "" : "s"), proven off
              \(platformLabel). Where a build verdict grounds the claim, the receipt is the
              compiler's own words at the pinned commit — and the same commit builds elsewhere,
              so the fence is real, not toolchain rot.</p>
        \(cards)
            </section>
        """
    }

    private static func unknownsSection(_ view: OnPlatformView, site: Site) -> String {
        guard !view.unknowns.isEmpty else { return "" }
        let items = view.unknowns.map { entry -> String in
            let why = entry.why.map { "<p class=\"unknown-why\">\(Html.escape($0))</p>" }
                ?? "<p class=\"unknown-why\">no claim recorded for this platform yet</p>"
            return """
                <li>
                  <p><a href="\(site.href("/package/\(entry.slug)/"))">\(Html.escape(entry.name))</a>
                  — <a href="\(site.href("/can/\(entry.capability.id)/?on=\(view.platform.rawValue)"))">\(Html.escape(entry.capability.label))</a></p>
                  \(why)
                </li>
            """
        }.joined(separator: "\n")
        return """
            <section class="on-section">
              <h2>Honest unknowns</h2>
              <p class="section-intro">\(view.unknowns.count) verdict\(view.unknowns.count == 1 ? "" : "s")
              we can't call yet — and refuse to guess. Each carries the reason on record.</p>
              <ul class="unknown-list">
        \(items)
              </ul>
            </section>
        """
    }
}
