# SwiftServe 🍦

**What Swift packages can actually do — served with proof.**

A healthy, popular package can still silently not support the one feature you
need on the one platform you ship. Health scores don't see it. Compile matrices
don't see it. SwiftServe reads the source — every `#if os(…)` guard, every
`@available` fence, at a pinned release tag — and answers the question that
actually burns integration days:

> **Does package X actually serve feature Y on platform Z?**

```bash
$ swiftserve capability-check livekit --capability "audio session" --platform macos

  🍦  Not served here   Audio session management · macOS · as of 2.15.1
  “So close — caught it before it cost you days.”

  The receipt
    AudioSessionEngineObserver  —  #if os(iOS) || os(visionOS) || os(tvOS)
    Sources/LiveKit/Audio/AudioSessionEngineObserver.swift:24
    https://github.com/livekit/client-sdk-swift/blob/2.15.1/Sources/…#L24

  Served on: iOS, macCatalyst, tvOS, visionOS
```

Every verdict is **version-pinned**, **evidence-anchored** (the permalink is
the exact line that decides it), and **honest** — `unknown` means "not verified
yet", never a fake all-clear. Claims of *absence* are held to the highest bar:
an explicit guard or availability fence, never mere silence.

## How truth is made

```
  discover → fetch @ tag → extract (SwiftSyntax, no compiling)
      public decls × #if guards × @available  =  the SURFACE
                            │
      capability labeling (LLM or human — doesn't matter)
                            │
      RecordValidator: every claim must anchor to the surface,
      or it dies (V01–V07: hallucinated symbols, ungrounded
      "supported", silence-as-"unsupported", inflated confidence)
                            │
      records (data/records/) → CLI dataset · static site · JSON API
```

Two layers. The **deterministic layer** parses; it never guesses — undecidable
conditions surface as `conditional`, unknown modules stay honest. The
**semantic layer** names capabilities; a validator rejects anything the parsed
surface can't prove. The labeler is replaceable; the contract is files.

## Explore it

```bash
swiftserve find --capability "noise cancellation" --platform macos   # who serves it?
swiftserve capability-check audiokit --capability midi --platform tvos --expect unsupported  # CI gate
swiftserve schema capability-record                                  # the JSON contract
make site && swift run SwiftServeServer                              # browse the truth tables
```

The generated site (in `Public/`) is the human face: search ("record audio on
watchos"), caniuse-style truth tables with clickable receipts, near-miss cards,
README badges per package, and a static JSON API under `/api/` for agents
(`/llms.txt` points the way).

---

## The Scoop — dependency health (the original front door)

Drop your `Package.resolved` and get a shareable dependency-health card — a
**Scoop** — narrated by **Swiftee**, the soft-serve mascot whose face reflects
your project's health. Now served at `/scoop/`.

```
  Static frontend            swiftserve CLI
  (drag & drop)              (terminal / CI)
        │                          │
        │ POST /analyze            │ scan
        ▼                          ▼
  SwiftServeServer ───────▶  SwiftServeCore  ◀─── (future: GitHub Action)
   (Hummingbird)             parse · enrich · score · mood
                             no external deps · macOS + Linux
                             ── canonical JSON is the one source of truth ──
```

## Run it

```bash
swift run SwiftServeServer        # serves http://127.0.0.1:8080  (set PORT to change)
```

Open the page, drag a real `Package.resolved` onto it, and watch Swiftee react.

Hit the API directly — it returns the *same* JSON the card renders from:

```bash
curl -X POST --data-binary @Package.resolved http://127.0.0.1:8080/analyze
```

## Scan from the terminal (CLI)

The `swiftserve` CLI reuses the exact same `SwiftServeCore` and prints the **same
canonical JSON** as the web `POST /analyze`. On a real terminal it renders a card;
when piped it emits JSON — so it's friendly to both humans and AI agents.

```bash
swift run swiftserve scan                 # scans ./Package.resolved → card (TTY) or JSON (piped)
swift run swiftserve scan path/to/Package.resolved
cat Package.resolved | swiftserve scan -  # read from stdin
swiftserve scan --json                    # force canonical JSON
swiftserve scan --min-score 80            # exit non-zero if overall < 80 (CI gate)
```

Set `GITHUB_TOKEN` to enable live GitHub enrichment (same as the server); pass
`--file-only` to force the offline path.

### For agents & CI

The CLI is built to be driven by scripts and AI agents (e.g. Claude Code):

- **Canonical JSON** — `swiftserve scan --json` prints the report on stdout
  (identical to the web `POST /analyze`). When stdout isn't a TTY, JSON is the
  default, so plain `swiftserve scan` in a pipeline already yields JSON.
- **Self-describing** — `swiftserve schema` prints the report's JSON Schema
  (Draft 2020-12) so an agent can validate/understand the output.
- **Structured errors** — in JSON mode, failures are emitted as
  `{"error": "…"}` on **stderr**, leaving stdout clean.
- **Exit codes** — `0` success · `1` overall score below `--min-score` ·
  `2` scan failed. (`1` vs `2` lets a caller distinguish "too low" from "broke".)
- **Color control** — `NO_COLOR` disables ANSI; `CLICOLOR_FORCE=1` forces it.

```bash
swiftserve scan --json Package.resolved | jq '.overall.mood'   # → "softSqueeze"
swiftserve scan --min-score 70 || echo "dependencies need attention"
swiftserve schema > report.schema.json
```

## Scan a binary for private APIs (Pillar 2)

The dreaded App Review "non-public API usage" rejection names a symbol and gives
you zero context. `scan-binary` catches those references *before* you submit — and
explains each one. It needs the compiled Mach-O, so it runs **locally; nothing
leaves your machine**.

```bash
swiftserve scan-binary MyApp.app           # .app, .framework, .dylib, or a raw Mach-O
swiftserve scan-binary path/to/Foo.framework --json
swiftserve scan-binary MyApp.app --fail-on high   # CI gate (exit 1 on a high finding)
swiftserve scan-binary MyApp.app --denylist my-list.json
```

It extracts imported symbols, ObjC classes, and selectors (via `nm`/`otool` from
the Xcode tools — no new deps), matches them against a denylist of known private
symbols, and reports each hit with the **framework, why Review flags it, the ITMS
code, the public alternative, and whether it's first-party or a dependency**. The
explanation layer — not the grep — is the point.

- **Denylist is data**: a bundled seed (`Resources/denylist.seed.json`, a curated
  proof-of-concept) loaded at runtime; override with `--denylist`.
- **Same output contract**: canonical JSON first, terminal summary rendered from it.
- **Honest limits** (surfaced in `warnings`): statically-linked deps merge into the
  main binary and can't be attributed separately yet; the seed denylist isn't
  comprehensive. Source-level scanning and a richer denylist come later.

### Scan your dependencies (transitive coverage)

The one nobody else gives: a private API hiding in a **binary dependency you can't
see into** that still gets *you* rejected. `scan-deps` scans a project's
dependency artifacts and **attributes each finding to the named dependency** —
answering "is this *my* problem or a *dependency's*?".

```bash
swiftserve scan-deps /path/to/MyApp            # Xcode or SwiftPM project dir
swiftserve scan-deps /path/to/MyApp --json     # canonical JSON (per-dependency rollup + findings)
swiftserve scan-deps /path/to/MyApp --source-packages <DerivedData>/SourcePackages   # pin location
swiftserve scan-deps /path/to/MyApp --app build/.../MyApp.app   # also scan your own code
```

It reads `Package.resolved` for versions, finds the dependency `*.xcframework`s
under `SourcePackages/artifacts/` (DerivedData auto-located for Xcode projects),
scans the shipping iOS slice, and reports findings **grouped into "your code" vs
each named dependency** — with versions, and a `scanned` / `sourceOnly` /
`notBuilt` status per dependency. When a dependency is the culprit, the copy makes
that a relief: *"Not on you — SomeSDK 3.1.0 is reaching into a private API."*

### Scan your source for dynamic private-API use

Binary scanning structurally **cannot** catch dynamic, string-based private-API
access — the private thing is a *string at runtime*, not a linked symbol.
`perform(Selector("_privateThing"))`, `value(forKey: "_ivar")`, `dlopen` of a
private framework, `NSClassFromString("_PrivateClass")` — none show up in the
Mach-O. `scan-source` catches exactly what the binary scan misses. It reads your
source, so it runs **locally; nothing leaves your machine**.

```bash
swiftserve scan-source MyApp/              # a project dir (scanned recursively) or a single file
swiftserve scan-source Sources/ --json     # canonical JSON
swiftserve scan-source MyApp/ --fail-on definite   # CI gate (exit 1 on a definite finding)
```

It parses Swift with **SwiftSyntax** (a real AST — so a `Selector("_x")` in a
comment or an unrelated string literal is *not* flagged; that's the difference
between a useful tool and a noisy grep), and Objective-C best-effort with text
patterns. Every finding is split by **confidence**:

- **definite** — the string matches a known denylist entry (or is a literal path
  under `/System/Library/PrivateFrameworks/`).
- **needs-review** — it *looks* private (a leading underscore, a private-framework
  prefix) but isn't on the denylist. A gentle "worth a look," never a failure.

Confidence requires evidence you can read: a constructed/interpolated value
(`"\(base)/PrivateFrameworks/\(name)"`) is needs-review at most, and Objective-C
hits (regex, no AST) are always needs-review and labeled as such. Each finding
carries an **exact `file:line:column`** — source scanning's edge over the binary
pass — in both the terminal summary and the canonical JSON.

## Use it from Claude Code

SwiftServe ships a Claude Code **skill**, so the agent reaches for it on its own —
say "check my dependency health" or "why did the App Store reject my app?" and it
runs the right scanner and explains the result.

```bash
make install     # release-build + put `swiftserve` on PATH + install the skill
                 # → ~/.local/bin/swiftserve  and  ~/.claude/skills/swiftserve/SKILL.md
```

Start a fresh Claude Code session; when a request matches (a dependency review, a
`Package.resolved`, an App Store "non-public API" rejection, a pre-submission
binary scan), Claude Code invokes `swiftserve scan` / `scan-binary` and reads the
canonical JSON. The skill source lives in `.claude/skills/swiftserve/SKILL.md`.

## Test it

```bash
swift test     # parser, mood mapping, scoring, enrichment helpers + private-API matcher/parsers
RUN_LIVE_GITHUB=1 swift test --filter liveEnrichment   # opt-in live GitHub smoke test
```

## How it works

- **`SwiftServeCore`** — the platform-agnostic brains. Codable models, the
  `Package.resolved` parser (format v2 + v3), the `Scorer`, the `Mood` state
  machine, and the `Enrichment` protocol. Zero external dependencies so it drops
  cleanly into the CLI (and a future GitHub Action).
- **`SwiftServeServer`** — a [Hummingbird](https://github.com/hummingbird-project/hummingbird)
  app exposing `POST /analyze` and serving the static frontend. (We dogfood
  Hummingbird on purpose.)
- **`swiftserve` (CLI)** — terminal/CI front door over the same Core: a card for
  humans, canonical JSON for pipes and AI agents, and a `--min-score` exit gate.
- **`SwiftServeScan`** — Pillar 2's pure detection core: the denylist model, the
  symbol matcher + `nm`/`otool` text parsers, and the source `SourceScanner`. It owns
  the "is this private" verdict for **every** surface (binary, deps, source), so the
  judgment lives in one place. No I/O; the CLI does the process-spawning.
- **`SwiftServeSource`** — the source-extraction layer for `scan-source`, and the
  *only* module that depends on SwiftSyntax (pinned to the toolchain's 603.x line).
  Its single job is turning source text into candidate sites (call + string argument +
  `file:line`); the verdict stays in `SwiftServeScan`. Isolating it keeps Core/Scan
  dependency-light and the parser swappable.
- **`Public/`** — hand-authored static HTML/CSS/JS. No Node, no bundler, no
  framework — ever. The Scoop card is rendered entirely from the `/analyze` JSON.

### The mood state machine

The score maps to exactly one mood; the card shows the matching sprite + voice line.

| mood          | score   | voice line                                |
|---------------|---------|-------------------------------------------|
| `partyMode`   | 95–100  | Immaculate. Sprinkles earned.             |
| `freshSwirl`  | 80–94   | Looking sharp — couple of easy wins.      |
| `softSqueeze` | 55–79   | Some melt setting in. Let's tidy up.      |
| `meltdown`    | 30–54   | Starting to drip. This needs attention.   |
| `dayOld`      | 0–29    | Rough night. We'll get you cleaned up.    |

Thresholds are deliberately skewed so most real projects land in `softSqueeze`
on a first scan (honest, not flattering) and `partyMode` is rare. They're
configurable in `ScoringConfig` / `MoodThresholds`.

### Enrichment degrades gracefully

The default `FileOnlyEnrichment` uses **zero network** — a useful report always
comes out of the file alone (supply-chain hygiene from pin shape, version-shape
staleness; neutral baselines elsewhere). `GitHubEnrichment` is a wired-in seam
for the next slice: live release/archived/license/contributor data, additive and
never required.

## Honest limitations (by design)

`Package.resolved` is a *flat* list, so a few things genuinely can't be known
from it alone — and SwiftServe reports them as `null` rather than guessing:

- **direct vs. transitive** and **graph depth** need your `Package.swift`
  manifest, which the web path deliberately never accepts.
- **latest version**, **maintenance recency**, **bus factor**, **license**, and
  **Swift 6 readiness** need a network scan (the `GitHubEnrichment` seam).

## Not yet

Private-API detection now spans binaries (`scan-binary`), dependency artifacts
(`scan-deps`), and first-party source (`scan-source`). Still ahead: scanning
dependency *source* (a deps × source combo), Objective-C via a real AST (libclang,
not regex), build-time pointers, inline suppression (`// swiftserve:ignore` — the
seam is left, not built), a GitHub Action, and any auth / accounts / persistence.
