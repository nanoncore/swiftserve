import Foundation
import SwiftServeCapability

// The generated pages. Truth tables render fully server-side — search, the
// ?on= focus view, and popover positioning are JavaScript sugar on top.

public enum CapabilityPage {

    /// The Apple mark for first-party rows — inline so it renders everywhere
    /// (the  glyph is a private-use codepoint that tofus off Apple devices).
    static let appleMark = """
    <svg class="apple-mark" viewBox="0 0 814 1000" aria-label="Apple" role="img"><path fill="currentColor" d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57-155.5-127C46.7 790.7 0 663 0 541.8c0-194.4 126.4-297.5 250.8-297.5 66.1 0 121.2 43.4 162.7 43.4 39.5 0 101.1-46 176.3-46 28.5 0 130.9 2.6 198.3 99.2zm-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 135.5-71.3z"/></svg>
    """

    public static func render(_ view: CapabilityView, site: Site) -> String {
        let capability = view.capability
        let headerCells = PlatformDisplay.order
            .map { "<th scope=\"col\">\(PlatformDisplay.label($0))</th>" }
            .joined()

        // First-party rows never interleave with packages — "you don't need
        // a dependency" and "you need one of these" are different answers.
        let builtIn = view.rows.filter { $0.record.package.firstParty }
        let packageRows = view.rows.filter { !$0.record.package.firstParty }

        let builtInSection: String
        if builtIn.isEmpty {
            builtInSection = ""
        } else {
            let rows = builtIn.map { row -> String in
                let record = row.record
                let cells = PlatformDisplay.order.map { platform in
                    VerdictCell.cell(claim: record.platforms[platform.rawValue], platform: platform,
                                     record: record, site: site)
                }.joined(separator: "\n")
                return """
                <tr>
                  <th scope="row">
                    <div class="row-head">
                      <div>
                        \(appleMark) <a href="\(site.href("/package/\(row.slug)/"))">\(Html.escape(record.package.name))</a>
                        <span class="pill pill-builtin">built in</span>
                        <span class="provenance">as of \(Html.escape(record.package.version))</span>
                      </div>
                      <a class="details-btn" href="\(site.href("/package/\(row.slug)/"))" aria-label="\(Html.escape(record.package.name)) details">Details</a>
                    </div>
                    \(record.notes.map { "<p class=\"builtin-note\">\(Html.escape($0))</p>" } ?? "")
                  </th>
                  \(cells)
                </tr>
                """
            }.joined(separator: "\n")
            builtInSection = """
                <section class="truth-table-wrap builtin-wrap">
                  <h2 class="builtin-head">Built into the OS — no dependency</h2>
                  <table class="truth-table builtin-table">
                    <thead><tr><th scope="col">Apple framework</th>\(headerCells)</tr></thead>
                    <tbody>
                \(rows)
                    </tbody>
                  </table>
                </section>
            """
        }

        let rows = packageRows.map { row -> String in
            let record = row.record
            let cells = PlatformDisplay.order.map { platform in
                VerdictCell.cell(claim: record.platforms[platform.rawValue], platform: platform,
                                 record: record, site: site)
            }.joined(separator: "\n")
            let fullMenu = PlatformDisplay.order.allSatisfy {
                record.platforms[$0.rawValue]?.status == .supported
            }
            let pill = fullMenu ? " <span class=\"pill pill-accent\">full menu</span>" : ""
            let supportedPlatforms = PlatformDisplay.order
                .filter { record.platforms[$0.rawValue]?.status == .supported }
                .map { PlatformDisplay.label($0) }
            return """
            <tr data-package="\(Html.escape(row.slug))" data-supported="\(supportedPlatforms.joined(separator: " "))">
              <th scope="row">
                <div class="row-head">
                  <div>
                    <a href="\(site.href("/package/\(row.slug)/"))">\(Html.escape(record.package.name))</a>\(pill)
                    <span class="provenance">as of \(Html.escape(record.package.version))</span>
                  </div>
                  <a class="details-btn" href="\(site.href("/package/\(row.slug)/"))" aria-label="\(Html.escape(record.package.name)) details">Details</a>
                </div>
              </th>
              \(cells)
            </tr>
            """
        }.joined(separator: "\n")

        let aliases = (capability.aliases ?? []).map(Html.escape).joined(separator: " · ")
        let empty: String
        if packageRows.isEmpty && !builtIn.isEmpty {
            empty = """
            <p class="empty-state">No third-party package verified for this yet — the OS itself covers it (above).
            Know one that belongs here? <a href="\(site.href("/about/#contribute"))">Tell us →</a></p>
            """
        } else if view.rows.isEmpty {
            if let note = capability.note {
                empty = """
                <p class="empty-state"><strong>Nothing on the menu — and that's the answer.</strong> \(Html.escape(note))
                Know a package that proves us wrong? <a href="\(site.href("/about/#contribute"))">Tell us →</a></p>
                """
            } else {
                empty = """
                <p class="empty-state">Nothing on the menu for this yet — the taxonomy knows the question,
                the index doesn't have the answer. <a href="\(site.href("/about/#contribute"))">Help verify a package →</a></p>
                """
            }
        } else {
            empty = ""
        }

        let main = """
            <section class="page-head">
              <p class="crumb"><a href="\(site.href("/menu/"))">Menu</a> / \(Html.escape(capability.id))</p>
              <h1>Can Swift packages do <em>\(Html.escape(capability.label.lowercased()))</em>?</h1>
              \(aliases.isEmpty ? "" : "<p class=\"aliases\">also known as: \(aliases)</p>")
              \(site.categoryPills(current: capability.id.split(separator: ".").first.map(String.init)))
            </section>
            <div class="near-miss-slot" data-near-miss hidden></div>
        \(builtInSection)
            <section class="truth-table-wrap">
              <table class="truth-table" data-capability="\(Html.escape(capability.id))">
                <thead><tr><th scope="col">Package</th>\(headerCells)</tr></thead>
                <tbody>
        \(rows)
                </tbody>
              </table>
              \(empty)
              <p class="table-legend">✓ serves it · ◐ with conditions · ✕ not served (proven) · ? not verified yet — hover any verdict for the receipt, click to pin it</p>
            </section>
        """
        return site.page(title: "\(capability.label) — can Swift packages do this?",
                         description: "Which Swift packages actually serve \(capability.label.lowercased()), on which Apple platforms — verdicts with source-line receipts.",
                         path: "/can/\(capability.id)/", wide: true, main: main)
    }
}

public enum PackagePage {

    public static func render(_ package: PackageView, site: Site) -> String {
        let headerCells = PlatformDisplay.order
            .map { "<th scope=\"col\">\(PlatformDisplay.label($0))</th>" }
            .joined()

        let rows = package.records.map { record -> String in
            let cells = PlatformDisplay.order.map { platform in
                VerdictCell.cell(claim: record.platforms[platform.rawValue], platform: platform,
                                 record: record, site: site)
            }.joined(separator: "\n")
            return """
            <tr>
              <th scope="row"><a href="\(site.href("/can/\(record.capability.id)/"))">\(Html.escape(record.capability.label))</a></th>
              \(cells)
            </tr>
            """
        }.joined(separator: "\n")

        let notes = package.records.compactMap { record in
            record.notes.map { "<p><strong>\(Html.escape(record.capability.label)):</strong> \(Html.escape($0))</p>" }
        }.joined(separator: "\n")

        let main = """
            <section class="page-head">
              <p class="crumb"><a href="\(site.href("/menu/"))">Menu</a> / \(package.firstParty ? "Apple frameworks" : "packages") / \(Html.escape(package.slug))</p>
              <h1>\(package.firstParty ? CapabilityPage.appleMark + " " : "")\(Html.escape(package.name))\(package.firstParty ? " <span class=\"pill pill-builtin\">built in</span>" : "")<span class="provenance-inline">as of \(Html.escape(package.version)) · <code>\(Html.escape(String(package.commit.prefix(8))))</code></span></h1>
              \(package.firstParty ? "<p class=\"builtin-note\">Ships with the OS — nothing to add to your Package.swift.</p>" : "")
              <p><a href="\(Html.escape(package.canonicalURL))" rel="noopener">\(Html.escape(package.canonicalURL))</a></p>
            </section>
            <section class="truth-table-wrap">
              <h2>What it serves, where</h2>
              <table class="truth-table">
                <thead><tr><th scope="col">Capability</th>\(headerCells)</tr></thead>
                <tbody>
        \(rows)
                </tbody>
              </table>
              <p class="table-legend">✓ serves it · ◐ with conditions · ✕ not served (proven) · ? not verified yet — hover any verdict for the receipt, click to pin it</p>
            </section>
            \(notes.isEmpty ? "" : "<section class=\"package-notes\"><h2>Notes</h2>\(notes)</section>")
            \(badgesSection(package, site: site))
        """
        return site.page(title: package.name,
                         description: "What \(package.name) actually serves on each Apple platform, verdict by verdict, with source receipts.",
                         path: "/package/\(package.slug)/", wide: true, main: main)
    }

    /// The growth loop: copy-ready embeds for the package's own README.
    /// Every badge click lands back on a truth table.
    private static func badgesSection(_ package: PackageView, site: Site) -> String {
        let matrixURL = site.absolute("/badge/\(package.slug)/matrix.svg")
        let verifiedURL = site.absolute("/badge/\(package.slug)/verified.svg")
        let packageURL = site.absolute("/package/\(package.slug)/")
        let matrixMarkdown = "[![What \(package.name) serves, verified](\(matrixURL))](\(packageURL))"
        let verifiedMarkdown = "[![\(package.records.count) capabilities verified by SwiftServe](\(verifiedURL))](\(packageURL))"

        let strips = package.records.map { record -> String in
            let stripURL = site.absolute("/badge/\(package.slug)/\(record.capability.id).svg")
            let canURL = site.absolute("/can/\(record.capability.id)/")
            let markdown = "[![Serves \(record.capability.label.lowercased())](\(stripURL))](\(canURL))"
            return """
            <div class="badge-row">
              <img src="\(site.href("/badge/\(package.slug)/\(record.capability.id).svg"))" alt="\(Html.escape(record.capability.label)) badge" height="20" />
              <button type="button" class="copy-btn" data-copy="\(Html.escape(markdown))">Copy markdown</button>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <section class="badges-section">
              <h2>Badges for your README</h2>
              <p>Maintainer of \(Html.escape(package.name))? These are yours — verified claims, linked to the receipts. Wrong verdict? That's a fix we want; see <a href="\(site.href("/about/#contribute"))">contribute</a>.</p>
              <div class="badge-row">
                <img src="\(site.href("/badge/\(package.slug)/verified.svg"))" alt="verified badge" height="20" />
                <button type="button" class="copy-btn" data-copy="\(Html.escape(verifiedMarkdown))">Copy markdown</button>
              </div>
              <div class="badge-row badge-row-matrix">
                <img src="\(site.href("/badge/\(package.slug)/matrix.svg"))" alt="capability matrix badge" />
                <button type="button" class="copy-btn" data-copy="\(Html.escape(matrixMarkdown))">Copy markdown</button>
              </div>
        \(strips)
            </section>
        """
    }
}

public enum MenuPage {

    public static func render(site: Site) -> String {
        let model = site.model
        // Group capabilities by their id prefix ("audio", "video", "speech"…).
        var groups: [String: [CapabilityView]] = [:]
        for view in model.capabilities {
            let prefix = view.capability.id.split(separator: ".").first.map(String.init) ?? "other"
            groups[prefix, default: []].append(view)
        }

        let sections = groups.keys.sorted().map { key -> String in
            let items = groups[key]!.map { view -> String in
                let dots = PlatformDisplay.order.map { platform -> String in
                    let count = view.supportedCount(on: platform)
                    let cls = count > 0 ? "dot dot-on" : "dot"
                    return "<span class=\"\(cls)\" title=\"\(PlatformDisplay.label(platform)): \(count) package\(count == 1 ? "" : "s")\"></span>"
                }.joined()
                let count = view.rows.isEmpty
                    ? "<span class=\"menu-count muted\">not verified yet</span>"
                    : "<span class=\"menu-count\">\(view.rows.count) package\(view.rows.count == 1 ? "" : "s")</span>"
                return """
                <li>
                  <a href="\(site.href("/can/\(view.capability.id)/"))">
                    <span class="menu-cap">\(Html.escape(view.capability.label))</span>
                    <span class="dots">\(dots)</span>
                    \(count)
                  </a>
                </li>
                """
            }.joined(separator: "\n")
            return """
            <section class="menu-group" id="\(Html.escape(key))">
              <h2>\(CategoryView.label(for: key))</h2>
              <ul class="menu-list">
            \(items)
              </ul>
            </section>
            """
        }.joined(separator: "\n")

        let main = """
            <section class="page-head">
              <h1>The Menu</h1>
              <p>Every capability the index can answer for. Dots show platform coverage across indexed packages.</p>
              <p>Shipping for the headset? <a href="\(site.href("/on/visionos/"))">The state of visionOS →</a>
              &nbsp;·&nbsp; For the wrist? <a href="\(site.href("/on/watchos/"))">The state of watchOS →</a></p>
              \(site.categoryPills())
            </section>
        \(sections)
        """
        return site.page(title: "The Menu",
                         description: "Every capability SwiftServe can answer for, with platform coverage at a glance.",
                         path: "/menu/", wide: true, main: main)
    }
}

public enum HomePage {

    public static func render(site: Site) -> String {
        let main = """
            <section class="hero">
              <img class="swiftee-sprite hero-sprite" src="\(site.href("/swiftee/swiftee-idle.png"))" alt="Swiftee, the SwiftServe mascot" width="180" height="180" />
              <h1>What does your app need to do?</h1>
              <p class="tagline">What Swift packages can actually do — served with proof.</p>
              <form class="hero-search" action="\(site.href("/"))" role="search" data-search>
                <input type="search" name="q" placeholder="try “record audio on watchos”…" aria-label="Search capabilities" autocomplete="off" />
                <p class="search-hint">press <kbd>/</kbd> to search — answers link to the exact source line that proves them</p>
              </form>
              <div class="results-slot" data-results hidden></div>
              <div class="chips">
                <a class="chip chip-accent" href="\(site.href("/menu/"))">Browse the Menu →</a>
                <a class="chip" href="\(site.href("/on/visionos/"))">The state of visionOS →</a>
                <a class="chip" href="\(site.href("/on/watchos/"))">The state of watchOS →</a>
                <a class="chip" href="\(site.href("/get/"))">Get SwiftServe →</a>
              </div>
              \(site.categoryPills())
            </section>
            <section class="home-why">
              <h2>Why this exists</h2>
              <p>A healthy, popular package can still silently not support the one feature you need
              on the one platform you ship. Health scores don't see it; compile matrices don't see it.
              SwiftServe reads the source — every <code>#if os(…)</code> guard, every
              <code>@available</code> fence — and answers with a receipt.</p>
              <p><a href="\(site.href("/about/"))">How verdicts are derived →</a></p>
            </section>
        """
        return site.page(title: "",
                         description: "Capability search for Swift packages: what they actually serve, on which Apple platforms, with source-line proof.",
                         path: "/", main: main)
    }
}

public enum AboutPage {

    public static func render(site: Site) -> String {
        let main = """
            <section class="page-head">
              <h1>How SwiftServe answers</h1>
              <p>Every verdict is version-pinned, evidence-anchored, and honest about its limits.</p>
            </section>
            <section id="methodology" class="prose">
              <h2>Methodology</h2>
              <p>Two layers. The <strong>deterministic layer</strong> parses a package's source at a pinned
              release tag — never compiling, never guessing — and extracts every public declaration with the
              <code>#if os(…)</code> / <code>canImport(…)</code> guards and <code>@available</code> fences
              around it. Guard logic is evaluated per platform with three-valued logic: provably present,
              provably absent, or honestly indeterminate.</p>
              <p>The <strong>semantic layer</strong> maps those declarations to human capability names
              ("noise cancellation"). Every claim must anchor to a declaration the deterministic layer
              confirms — a validator rejects any claim whose symbol, file, line, or platform truth doesn't
              match the extracted surface. Claims of <em>absence</em> are held to the highest bar: they
              require an explicit guard or availability fence, never mere silence.</p>
            </section>
            <section id="confidence" class="prose">
              <h2>Confidence</h2>
              <p>No verdict reaches 1.0. Ceilings apply by evidence strength: source guards and symbols rate
              highest; indeterminate guards cap at 0.6; README-only claims cap at 0.3 and can only ever say
              "unknown". Packages shipping binary <code>xcframework</code>s cap at 0.8 — the real fence may
              live inside the binary, and we say so instead of pretending.</p>
            </section>
            <section id="limits" class="prose">
              <h2>Honest limits (by design)</h2>
              <ul>
                <li>Objective-C surface isn't parsed yet — such packages read "not verified", never a fake verdict.</li>
                <li>Macro-generated API is invisible to parsing; affected declarations carry a confidence cap.</li>
                <li>Binary targets hide their platform truth; flagged, capped, noted.</li>
                <li>A verdict is a fact about a <em>pinned version</em>. Packages change — record freshness is shown on every row.</li>
              </ul>
            </section>
            <section id="contribute" class="prose">
              <h2>Contribute</h2>
              <p>Got burned by a feature×platform gap? That story is a record waiting to happen —
              open an issue with the package, feature, and platform, and it joins the index with
              your name on the receipt.</p>
            </section>
        """
        return site.page(title: "About",
                         description: "How SwiftServe derives capability verdicts: source-level extraction, grounded labeling, honest confidence.",
                         path: "/about/", main: main)
    }
}

public enum AgentsPage {

    public static func render(site: Site) -> String {
        let capabilityExample = site.model.capabilities.first { !$0.rows.isEmpty }?.capability.id
            ?? "audio.noise-cancellation"
        let curl1 = "curl -s \(site.absolute("/api/capabilities/\(capabilityExample).json")) \\\n  | jq '.packages[] | select(.platforms.macOS.status == \"supported\") | .packageName'"
        let curl2 = "curl -s \(site.absolute("/api/index.json")) | jq '.endpoints'"

        let main = """
            <section class="page-head">
              <h1>For agents</h1>
              <p>The records are the API: static JSON, stable schema, evidence permalinks.
              Consult it <em>before</em> adding a Swift dependency.</p>
              <p>Zero install: the endpoints below. In Claude Code: the plugin —
              <a href="\(site.href("/get/"))">two pastes</a>. Offline and CI:
              <a href="\(site.href("/get/"))">the CLI</a>.</p>
            </section>
            <section class="prose">
              <h2>Endpoints</h2>
              <ul>
                <li><code>/api/index.json</code> — start here (endpoint map + schemaVersion)</li>
                <li><code>/api/capabilities/{id}.json</code> — the question you're asking: who serves this, where, with what proof</li>
                <li><code>/api/packages/{slug}.json</code> — a package's full records</li>
                <li><code>/api/taxonomy.json</code> — the capability vocabulary + aliases</li>
                <li><code>/api/search-index.json</code> — compact name/alias index</li>
              </ul>
              <p><strong>Schema promise:</strong> breaking changes bump <code>schemaVersion</code> and the
              <code>/api/schemas/…</code> documents; additive fields may appear any time. Treat unknown
              fields as forwards-compatible.</p>
            </section>
            <section class="prose">
              <h2>Examples</h2>
              <pre><code>\(Html.escape(curl1))</code></pre>
              <pre><code>\(Html.escape(curl2))</code></pre>
              <h2>Reading a verdict</h2>
              <p><code>supported</code> / <code>unsupported</code> are grounded in parsed source (guards,
              availability) at a pinned tag — each evidence item carries a <code>permalink</code> to the
              deciding line. <code>unknown</code> means "not verified", never "no". Confidence never
              reaches 1.0; anything ≤ 0.3 rests on README-grade evidence only.</p>
              <h2>CLI</h2>
              <p>The same dataset ships in the CLI for offline/CI use
              (<a href="\(site.href("/get/"))">install options</a>):</p>
              <pre><code>swiftserve capability-check livekit --capability "noise cancellation" --platform macos
        swiftserve find --capability audio.recording --platform watchos
        swiftserve schema capability-record</code></pre>
              <p>Exit codes: 0 answered · 1 <code>--expect</code> mismatch (CI gate) · 2 not found.</p>
            </section>
        """
        return site.page(title: "For agents",
                         description: "SwiftServe's capability index as a static JSON API: endpoints, schema promise, examples.",
                         path: "/agents/", main: main)
    }
}

public enum GetPage {

    /// The GitHub home of the project — also the plugin marketplace and the
    /// release binaries. One place to change if the account ever moves.
    public static let repoSlug = "nanoncore/swiftserve"
    /// Flip when the first tagged release exists (binaries + Homebrew tap);
    /// until then the CLI lane shows build-from-source as the live path.
    public static let firstReleaseCut = true

    /// A copy-paste command row: the command plus the "Scooped!" copy button.
    static func cmd(_ command: String) -> String {
        """
        <div class="cmd-row">
          <pre><code>\(Html.escape(command))</code></pre>
          <button type="button" class="copy-btn" data-copy="\(Html.escape(command))">Copy</button>
        </div>
        """
    }

    public static func render(site: Site) -> String {
        let cli: String
        if firstReleaseCut {
            cli = """
            <p>Homebrew:</p>
            \(cmd("brew install \(repoSlug.split(separator: "/")[0])/tap/swiftserve"))
            <p>Or the installer script (fetches the latest signed release into <code>~/.local/bin</code>):</p>
            \(cmd("curl -fsSL \(site.absolute("/install.sh")) | sh"))
            <p>Or from source:</p>
            \(cmd("git clone https://github.com/\(repoSlug) && cd swiftserve && make install"))
            """
        } else {
            cli = """
            <p>From source today — Homebrew and a one-line installer land with the first tagged release:</p>
            \(cmd("git clone https://github.com/\(repoSlug) && cd swiftserve && make install"))
            <p><code>make install</code> puts <code>swiftserve</code> in <code>~/.local/bin</code> and installs
            the Claude Code skill for local sessions.</p>
            """
        }

        let main = """
            <section class="page-head">
              <h1>Get SwiftServe</h1>
              <p>Three ways in, ordered by setup cost: point your agent at the hosted index
              (zero install), teach your coding agent the skill (a paste or two), or install
              the CLI.</p>
            </section>
            <section class="prose">
              <h2>1 · Your agent — zero install</h2>
              <p>The records are the API: static JSON, stable schema, evidence permalinks.
              Any agent that can <code>curl</code> is already set up:</p>
              \(cmd("curl -s \(site.absolute("/api/capabilities/audio.noise-cancellation.json"))"))
              <p>Start at <code>/api/index.json</code> for the endpoint map — full contract on the
              <a href="\(site.href("/agents/"))">agents page</a>.</p>
            </section>
            <section class="prose">
              <h2>2 · Your coding agent — the skill</h2>
              <p><strong>Claude Code</strong> — two pastes. Versioned, auto-updating, and it teaches
              Claude to consult the index <em>before</em> adding any Swift dependency:</p>
              \(cmd("/plugin marketplace add \(repoSlug)"))
              \(cmd("/plugin install swiftserve@swiftserve"))
              <p>Then just ask: <em>“can LiveKit do noise cancellation on macOS?”</em></p>
              <p><strong>Codex</strong> — the same skill, same file, in the open <code>SKILL.md</code>
              format Codex speaks. One paste in a terminal:</p>
              \(cmd("mkdir -p ~/.agents/skills/swiftserve && curl -fsSL \(site.absolute("/skill.md")) -o ~/.agents/skills/swiftserve/SKILL.md"))
              <p>(Older Codex builds read <code>~/.codex/skills</code> instead — same file, same paste,
              different path. Mention it with <code>$swiftserve</code> or just ask.)</p>
              <p><strong>Any other agent</strong> that speaks the skill format — same one-liner,
              pointed at its skills directory. The skill is plain instructions over the hosted
              API and the CLI; nothing in it is agent-specific.</p>
            </section>
            <section class="prose">
              <h2>3 · The CLI — offline checks, CI gates, scanners</h2>
              <p>Everything the hosted index answers, plus what needs your machine: dependency
              health (<code>scan</code>), private-API detection (<code>scan-binary</code>,
              <code>scan-deps</code>), and <code>--expect</code> CI gates.</p>
              \(cli)
            </section>
        """
        return site.page(title: "Get SwiftServe",
                         description: "Point your agent at the hosted index, add the Claude Code plugin, or install the CLI.",
                         path: "/get/", main: main)
    }
}

public enum NotFoundPage {

    public static func render(site: Site) -> String {
        let main = """
            <section class="hero">
              <img class="swiftee-sprite hero-sprite" src="\(site.href("/swiftee/swiftee-melt.png"))" alt="Swiftee, melting" width="180" height="180" />
              <h1>This page melted.</h1>
              <p class="tagline">The link is gone, but the truth is still on the menu.</p>
              <form class="hero-search" action="\(site.href("/"))" role="search" data-search>
                <input type="search" name="q" placeholder="search capabilities…" aria-label="Search capabilities" autocomplete="off" />
              </form>
              <div class="results-slot" data-results hidden></div>
              <div class="chips"><a class="chip chip-accent" href="\(site.href("/menu/"))">Browse the Menu →</a></div>
            </section>
        """
        return site.page(title: "This page melted",
                         description: "404 — the page melted.", path: "/404.html", main: main)
    }
}
