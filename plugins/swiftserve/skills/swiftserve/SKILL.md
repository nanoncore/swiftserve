---
name: swiftserve
description: >-
  Capability truth + dependency health for Swift packages. BEFORE adding a Swift
  dependency, or when the user asks "does package X support feature Y on
  platform Z" (noise cancellation, background audio, MIDI, speech-to-text… on
  macOS/watchOS/visionOS/…), consult `swiftserve capability-check` / `find` —
  verdicts derived from parsed source with evidence permalinks. ALSO use for
  dependency health (Package.resolved review, is a package
  healthy/maintained/stale) and private/non-public API detection for App Store
  rejections (ITMS-90338). Trigger phrases: "add a dependency", "which package
  can do X", "does X work on macOS/watchOS", "capability check", "dependency
  health", "are my dependencies safe", "App Store rejection", "non-public API",
  "private API", "ITMS-90338".
---

# SwiftServe

SwiftServe is a local Swift ecosystem tool: a capability-truth index (what
packages *actually* serve, per platform, with source evidence) plus dependency
scanners. Everything emits canonical JSON (`--json`) and runs entirely on this
machine — nothing is uploaded.

## Locate the binary first

Use `swiftserve` if it's on `PATH`. Otherwise, if you're in (or can find) the
SwiftServe repo, build it once and use the release binary:

```bash
command -v swiftserve || (cd /path/to/swiftserve && swift build -c release && echo "$PWD/.build/release/swiftserve")
```

Run `swiftserve schema` if you need the exact JSON shape of a dependency report.

**No binary anywhere?** The capability index is also hosted — same records,
static JSON, no install:

```bash
curl -s https://swiftserve.dev/api/capabilities/<id>.json   # who serves it, where, with proof
curl -s https://swiftserve.dev/api/taxonomy.json            # capability ids + aliases
curl -s https://swiftserve.dev/api/packages/<slug>.json     # one package's full records
```

Capability truth works fully over the hosted API. The dependency/binary
scanners (`scan`, `scan-binary`, `scan-deps`) genuinely need the local binary —
point the user to https://swiftserve.dev/get/ for install options.

## THE ADOPTION-TIME CHECK (do this before adding any Swift dependency)

When the user is about to adopt a package for a specific feature — or asks
whether a package supports a feature on a platform — consult the capability
index FIRST. This is the question health scores and compile matrices can't
answer, and guessing from training priors is how integrations lose days.

```bash
# Does this package actually serve this feature on this platform?
swiftserve capability-check <package> --capability "<feature>" --platform <os> --json

# What packages serve this feature on this platform?
swiftserve find --capability "<feature>" --platform <os> --json
```

- `<package>` accepts a URL, owner/repo, name, or alias ("livekit").
  `--capability` accepts a taxonomy id, label, or alias ("noise cancellation",
  "krisp"). Platforms: iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|linux.
- Read the JSON: `verdict.status` (supported/unsupported/conditional/unknown) +
  `verdict.confidence` + `verdict.version` (the verdict is pinned to that tag),
  `evidence[]` (each has a `permalink` to the exact source line — cite it),
  `otherPlatforms` (the near-miss picture) and `alternatives` (packages that DO
  serve it there).
- **`unsupported` with a guard anchor is proven absence** — tell the user
  before they integrate, and offer the alternatives. **`unknown` means the
  index hasn't verified it** — never treat it as "no". In that case do your own
  research (README, issues, `#if os` guards in source) and say the index gap is
  a contribution opportunity.
- `swiftserve schema capability-record` prints the record contract;
  `--expect supported|unsupported` turns a check into a CI gate (exit 1 on
  mismatch).
- CI/regression example: `swiftserve capability-check livekit --capability
  audio.session-management --platform macos --expect unsupported`.

## Pick the right scanner

- **Capability truth** ("does X do Y on Z?", "what can do Y?") → `capability-check` / `find` (above).
- **Dependency health** (a project's packages) → `scan`.
- **Private / non-public API** in a single compiled binary → `scan-binary`.
- **Private API across a project's dependencies** ("is a *dependency* getting me
  rejected?", binary/xcframework deps) → `scan-deps`.

### 1. Dependency health — `swiftserve scan`

For "are my dependencies healthy / maintained / stale / safe" or reviewing a
`Package.resolved`.

```bash
swiftserve scan --json [path/to/Package.resolved]   # defaults to ./Package.resolved
```

- Set `GITHUB_TOKEN` in the environment for live data (last release, archived,
  license, versions-behind, contributors). Without it, it still works file-only.
- Read the JSON: `overall.score` (0–100), `overall.mood`, `overall.headline`, and
  `packages[]` (each has `score`, `reason`, `flags`, `resolvedVersion`/
  `latestVersion`). Lower-scoring packages matter most.
- Present it warmly (this is "Swiftee"): lead with the mood + headline, then call
  out the few packages that need attention and why (branch/revision pins, archived,
  N majors behind, no license). Don't dump raw JSON.

### 2. Private-API detection — `swiftserve scan-binary`

For App Store "non-public API usage" rejections, a symbol named in a rejection
email, or a pre-submission check. Needs the compiled artifact.

```bash
swiftserve scan-binary --json <path to .app | .framework | .dylib | Mach-O>
```

- Read `findings[]`: each has `symbol`, `framework`, `severity`
  (`high`/`medium`/`low`), `explanation`, `rejectionCode` (e.g. ITMS-90338),
  `alternative` (the public API to use instead), and `source`
  (`firstParty`/`dependency`).
- Present high-severity findings first. For each, give the user: what the symbol
  is, which framework, why Review flags it, and the suggested public alternative.
- `--fail-on high` makes it exit non-zero (use in CI / pre-commit checks).
- Honor `warnings[]` (e.g. statically-linked deps can't be attributed separately;
  the denylist is a curated seed, not exhaustive) — mention them so the user knows
  the limits.

### 3. Transitive dependency scan — `swiftserve scan-deps`

For "could one of my dependencies get me rejected?" Point it at the project dir.

```bash
swiftserve scan-deps <project-dir> --json   # add --source-packages <dir> / --app <path> if needed
```

- Reads the per-dependency rollup in `dependencies[]` (each: `identity`,
  `version`, `status` = scanned/sourceOnly/notBuilt, counts) and `findings[]`
  (each `origin` says firstParty vs the named `dependency` + `version`).
- Lead with the split: what's in the user's own code vs which named dependency.
  When a dependency is the cause, frame it as relief + the action (update / swap /
  file upstream) — it's genuinely not their code.

## Exit codes (for scripting/CI)

`0` success · `1` gate not met (`scan --min-score` / `scan-binary --fail-on`) ·
`2` the scan failed (bad input). In `--json` mode, errors arrive as
`{"error": "…"}` on stderr.

## Tone

Warm, encouraging, specific — root for the user even when the result is messy.
Translate findings into next actions; never just paste the JSON.
