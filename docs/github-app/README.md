# SwiftServe GitHub App MVP

The hosted executable accepts signed pull-request and base-branch webhooks,
durably records orchestration metadata, and publishes one aggregate Check Run
named `SwiftServe / Upgrade Receipt` for each pull-request head SHA. Dependabot,
Renovate, and human dependency pull requests follow the same path.

Every changed file whose final component is `Package.resolved` is evaluated
independently. Paths are sorted, base/head content is fetched at the event's
exact commit SHAs, and the root `.swiftserve.json` is read once from the exact
base SHA. Added/deleted sides are empty pin sets in memory and renames use the
old base path plus new head path. Package identities are intentionally not
deduplicated across lockfiles. The aggregate verdict is the worst receipt
verdict; malformed inputs fail closed without hiding valid sibling receipts.
The pull request's authoritative `changed_files` count is compared with the
paginated listing, so GitHub's 3,000-file listing ceiling or any incomplete
enumeration fails the aggregate Check closed instead of silently skipping a
lockfile.

The App reuses `ReceiptEngine`, `ReceiptPolicy`, gate mapping, bundled exact
capability evidence, and `UpgradeReceiptMarkdownRenderer`. It does not clone
dependency repositories or perform live capability rechecks.

## GitHub App setup

Configure the App with:

- Webhook URL: `https://<host>/webhooks/github`
- Contents: read-only
- Pull requests: read-only
- Checks: read and write
- Events: pull request and push

Required environment variables:

- `SWIFTSERVE_GITHUB_APP_ID`
- `SWIFTSERVE_GITHUB_PRIVATE_KEY` — PEM with real newlines or `\n` escapes
- `SWIFTSERVE_GITHUB_WEBHOOK_SECRET`

Optional variables and defaults:

| Variable | Default | Purpose |
|---|---:|---|
| `SWIFTSERVE_GITHUB_WEBHOOK_SECRET_PREVIOUS` | unset | Previous secret during rotation |
| `SWIFTSERVE_GITHUB_GATE` | `block` | `review` or `block` gate threshold |
| `SWIFTSERVE_GITHUB_JOB_STORE` | `./swiftserve-github.sqlite` | Durable SQLite path |
| `SWIFTSERVE_GITHUB_WORKER_CAPACITY` | `4` | Global active-job bound |
| `SWIFTSERVE_GITHUB_INSTALLATION_CONCURRENCY` | `2` | Active jobs per installation |
| `SWIFTSERVE_GITHUB_LEASE_SECONDS` | `120` | Crash-recovery lease |
| `SWIFTSERVE_GITHUB_RETENTION_SECONDS` | `604800` | Completed idempotency retention (7 days) |
| `SWIFTSERVE_GITHUB_RETRY_MAX_ATTEMPTS` | `6` | Durable attempt budget |
| `SWIFTSERVE_GITHUB_RETRY_MAX_ELAPSED_SECONDS` | `900` | Durable elapsed retry budget |
| `SWIFTSERVE_GITHUB_MAX_PAYLOAD_BYTES` | `1048576` | Webhook body limit |
| `SWIFTSERVE_GITHUB_MAX_LOCKFILE_BYTES` | `5242880` | Decoded lockfile limit |
| `SWIFTSERVE_GITHUB_MAX_POLICY_BYTES` | `262144` | Decoded policy limit |
| `SWIFTSERVE_GITHUB_MAX_RESPONSE_BYTES` | `8388608` | GitHub response limit |
| `SWIFTSERVE_GITHUB_CONNECT_TIMEOUT_SECONDS` | `10` | Connection/request-start timeout |
| `SWIFTSERVE_GITHUB_REQUEST_TIMEOUT_SECONDS` | `30` | Whole-resource timeout |
| `SWIFTSERVE_GITHUB_API_URL` | `https://api.github.com` | Configured HTTPS API origin |
| `HOST` / `PORT` | `127.0.0.1` / `8080` | Listener |

HTTP API overrides are accepted only for a loopback host when
`SWIFTSERVE_RUNTIME_MODE=test`; production accepts HTTPS origins only. User
information, passwords, query strings, and fragments are rejected in the
configured origin.

## Storage schema and retention

Migration `v1_create_jobs` creates `github_jobs` with unique GitHub delivery and
immutable-work idempotency keys. Rows contain only:

- installation, repository, pull-request, base-ref, base-SHA, and head-SHA identifiers;
- external/check-run IDs;
- attempt count and pending/running/completed/failed/superseded state;
- scheduling, lease, creation, completion, and expiry timestamps;
- a fixed sanitized terminal category.

The store never receives raw webhook bodies, lockfile/policy/source content,
authorization headers, installation tokens, App JWTs, private keys, or webhook
secrets. SQLite runs with WAL, foreign keys, full synchronous durability, GRDB
migrations, and transactional claim/update operations. Completed, failed, and
superseded records remain for seven days by default. The worker scheduler runs
bounded pruning hourly; retention is bounded by expiry, not by repository-content
storage.

GRDB 7.10.0 was selected after a pre-adoption SwiftServe health check of its
exact resolved pin. File-only evidence showed a release pin, no duplicate,
conflict, branch, or revision flags, and hygiene 90. GRDB supplies migrations,
transactions, busy handling, and WAL concurrency instead of custom storage and
locking primitives. Its 7.10 release includes Linux adjustments, but upstream
describes Linux support as contributor-supported rather than officially
maintained; Linux release builds and the acceptance target remain required.

## Delivery, leases, and supersession

The webhook returns 202 only after the SQLite transaction commits. A duplicate
delivery or identical immutable work is acknowledged without another row.
Claims atomically increment attempts and install a worker/expiry lease. Active
workers renew that lease every one-third of its configured duration with an
owner-checked update. A failed renewal cancels the analysis and prevents later
Check mutations; other workers cannot claim a healthy lease. A process restart
can claim pending work immediately, while a crashed running job becomes
claimable after lease expiry.

Completed work remains idempotent for the retention window. A redelivery of
failed work revives the same row, resets its attempt/elapsed retry budget, and
preserves its Check Run ID so an `in_progress` Check can recover. Failed older
work is not revived after a newer active or completed state for that pull request.

New PR state marks older pending/running states superseded. A worker also
re-reads the PR base ref, base SHA, and head SHA before starting and before final
publication. An obsolete worker cannot publish onto the current head, and
head-specific external IDs keep Check upserts isolated. The Check is created or
updated as `in_progress`, its ID is persisted immediately, and that same Check
is completed after aggregation.

The worker scheduler enforces both global and per-installation concurrency.
Shutdown first stops durable acceptance, cancels the scheduler, and either
finishes or releases active leases. Already acknowledged rows therefore remain
recoverable.

## Retry and rate-limit policy

The GitHub client centrally classifies network timeouts, 429, primary rate-limit
exhaustion, secondary/abuse limits, and retryable 500/502/503/504 responses. It
honors `Retry-After`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset`. The first
401 invalidates only the rejected installation token, refreshes once, and
retries; a second 401 and permanent 403/404 responses are not retried forever.
Primary-limit headers take precedence for both 403 and 429 responses. A
secondary limit without an explicit deadline is scheduled at least 60 seconds
later, as required by GitHub's rate-limit guidance.

Retryable work releases its lease and is rescheduled in SQLite. Workers never
sleep through a rate-limit window while consuming processing capacity. Backoff
is exponential with jitter, capped at 60 seconds per computed delay and bounded
by both attempt and elapsed budgets (6 attempts/15 minutes by default). Server
deadlines override an earlier computed backoff. Exhaustion stores only
`retry_budget_exhausted`.

## Security and privacy boundary

- Repository coordinates, content paths, SHAs, and query values are validated
  and encoded through URL components; only the configured API origin is used.
- Production sessions reject cross-origin redirects and do not accept cookies.
- Webhook, response, lockfile, and policy sizes plus connection/resource
  durations are bounded.
- Paths are untrusted Markdown. Controls become visible escapes, code fences
  expand around backticks, and table pipes are escaped.
- Check output preserves the aggregate result/overview and worst sections first,
  omits only complete lockfile sections, and reports the omitted count.
- GitHub response bodies and repository content are never logged. Public errors
  and persistent terminal categories are fixed and credential-free.
- Current and optional previous HMAC secrets are both accepted during rotation.
  Remove the previous value after GitHub deliveries use the new secret.
- Operational counters have no labels and never contain repository names,
  paths, lockfile identities, or content.

## Health and metrics

- `GET /livez` returns 200 while the process serves requests.
- `GET /readyz` returns 200 only after configuration, migrations/store access,
  worker startup, and durable acceptance are ready; it returns 503 during
  shutdown or a dependency failure.
- `GET /metrics` returns privacy-safe JSON counters for accepted/rejected
  webhooks, queue depth, active/completed/failed/retried/superseded jobs,
  rate-limit waits, completed Check count, and total publication latency.

These endpoints are deployment-neutral and require the hosting platform to map
its probes and telemetry collection.

## Runbook

Build and validate:

```sh
swift test
swift build -c release --product swiftserve-github-app
make receipt-spike
make github-app-spike
make github-app-mvp
```

Linux CI, tagged Linux releases, and the deployment image use Swift 6.1 because
the resolved Hummingbird, swift-crypto, and GRDB releases require Swift tools
6.1. The manifest syntax declaration remains 6.0, but the current resolved
dependency graph has an effective Swift 6.1 build-toolchain minimum.
Linux builds also install the distribution's SQLite development headers for
GRDB's system SQLite module.

Start the service with secrets injected by a secret manager:

```sh
.build/release/swiftserve-github-app
```

Recovery actions:

1. If readiness is down, validate required configuration and writable storage,
   then inspect only sanitized startup categories.
2. Preserve the SQLite database across restarts. Pending work resumes; expired
   leases recover automatically.
3. For a rate-limit backlog, reduce worker/per-installation concurrency or wait
   for the recorded reset. Do not delete jobs or bypass budgets.
4. For a bad secret rotation, restore the last valid secret as current or
   previous, verify signed delivery acceptance, then rotate again.
5. If a Check is stuck `in_progress`, redeliver the webhook. The durable
   idempotency key and stored Check ID update the same run.
6. Back up/restore only the SQLite orchestration database if required. It has no
   repository contents or credentials. Expired terminal rows may be pruned.

## Real smoke test

When credentials and a suitable repository are available, open a PR changing
at least two `Package.resolved` files, verify one aggregate Check, redeliver the
webhook, and verify no duplicate job or Check. Never commit App credentials or
weaken deterministic verification when credentials are unavailable.

## Remaining production risks

- The SQLite design targets one hosted instance. It is not cross-region or HA.
- A full disk can prevent durable acknowledgment and makes readiness fail; the
  hosting layer must alert on disk capacity and persist the database volume.
- GRDB's Linux support is contributor-supported, so Linux release/acceptance
  builds are a deployment gate.
- GitHub output limits can omit whole receipt sections; the aggregate verdict,
  overview, and omission count remain visible, but there is intentionally no
  long-term receipt storage or dashboard.
- Base-push fan-out is durable as one job but is not a cross-instance fan-out
  queue; this is acceptable for the single-instance MVP and should be revisited
  before HA work.
