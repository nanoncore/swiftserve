# Upgrade Receipt architecture and compatibility

SwiftServe 0.7.0 adds a second versioned artifact, the Upgrade Receipt. It is
deliberately separate from the v1 dependency-health Scoop: `Report` and
`ReportSchema` keep their field sets and behavior, while `UpgradeReceipt` starts
at `receiptVersion: 1` and has its own schema and CLI command.

## Decisions

- `SwiftServeReceipt` is a library target containing deterministic lockfile
  comparison, SemVer precedence, policy and gate evaluation, capability
  projection, canonical Markdown rendering, and Codable contracts. It depends
  on `SwiftServeCore` and `SwiftServeCapability`, with no I/O and no external
  dependencies.
- `SwiftServeEvidence` owns the immutable bundled capability snapshot and its
  loader so CLI and hosted consumers use identical exact-version evidence while
  `SwiftServeCapability` remains pure.
- Both inputs use `PackageResolvedParser`; normalized SwiftPM identities and
  canonical repository URLs come from `RepoIdentity`. A repository change for
  one identity therefore remains one source-change finding.
- The CLI owns files, environment, GitHub enrichment, temporary source
  checkouts, extraction, and terminal-card rendering. Health enrichment
  receives one pin per changed canonical repository, so base/head scores share
  one snapshot.
- Capability records are exact-version evidence. Without recheck, a head pin
  must exactly equal the record version or its result is `unverified`. With
  recheck, temporary checkouts feed the existing `SurfaceBuilder` and pure
  `RecheckEngine`; records, locks, and corpus caches are never written.
- The policy is JSON/Foundation only. It is validated before decoding for
  duplicate keys and rejects unknown versions, keys, rules, severities,
  platforms, and malformed requirements.
- `pass` means only that no configured rule was violated. It is not a universal
  safety claim and does not replace compilation, tests, or application review.
- Existing CLI output selection and exit meanings remain: human output on a
  TTY, canonical JSON in a pipe, gate failure 1, trustworthy-input failure 2.
  `diff --markdown` is the explicit GitHub Step Summary surface.

## Network and privacy boundary

No lockfile or source is uploaded to SwiftServe. Optional GitHub calls go
directly to GitHub, using `GITHUB_TOKEN` only as an authorization header.
Receipts do not include tokens, credentials, fetched source contents, or
credential-bearing repository URLs. Capability rechecks use temporary local
checkouts and delete them after extraction.

Live receipt rechecking currently supports accessible GitHub semantic-version
tags. Branch pins, revision pins, other forges, and inaccessible private
repositories report `unavailable`; they are never silently treated as passing
evidence.
