# SwiftServe GitHub App spike

This executable is the first hosted Upgrade Receipt slice. It accepts signed
pull-request and branch-push webhooks, authenticates as the event's GitHub App
installation, fetches immutable inputs, runs the reusable receipt engine with
exact bundled capability evidence, and creates or updates one Check Run named
`SwiftServe / Upgrade Receipt`.

It is intentionally separate from `SwiftServeServer`. It does not store source,
webhook payloads, lockfiles, policy, installation tokens, or private keys.

## Create and configure the GitHub App

Create a GitHub App owned by the intended user or organization and configure:

- Webhook URL: `https://<host>/webhooks/github`
- Webhook secret: a new high-entropy secret
- Repository permissions:
  - Contents: **Read-only**
  - Pull requests: **Read-only**
  - Checks: **Read and write**
- Subscribe to events: **Pull request** and **Push**

Install it on the test repository. The spike accepts `opened`, `synchronize`,
and `reopened`, plus `edited` only when the PR base changed. A branch push
reprocesses open PRs targeting that branch so a policy or lockfile change in the
base cannot leave an obsolete Check in place. Other signed actions, tag pushes,
and branch deletions are acknowledged and ignored. It never filters on sender
identity, so Dependabot, Renovate, and manually opened dependency PRs follow the
same path.

Generate and download an RSA private key from the App settings. Keep the App ID,
private key, and webhook secret in the runtime's secret store.

## Environment

The required variables are:

- `SWIFTSERVE_GITHUB_APP_ID`
- `SWIFTSERVE_GITHUB_PRIVATE_KEY` — PEM text, either with literal newlines or
  `\n` escapes
- `SWIFTSERVE_GITHUB_WEBHOOK_SECRET`

Optional variables:

- `SWIFTSERVE_GITHUB_GATE` — `block` (default) or `review`
- `SWIFTSERVE_GITHUB_MAX_PAYLOAD_BYTES` — default 1 MiB
- `SWIFTSERVE_GITHUB_WORKER_CAPACITY` — default 16 in-flight logical checks
- `SWIFTSERVE_GITHUB_API_URL` — default `https://api.github.com`; HTTP is
  accepted only for loopback test servers
- `HOST` — default `127.0.0.1`
- `PORT` — default `8080`

See `.env.example` for names only. The executable validates configuration at
startup and emits structured, secret-free errors to standard error.

## Run and test locally

Build and start the executable with secrets injected by your local secret
manager:

```sh
swift build --product swiftserve-github-app
.build/debug/swiftserve-github-app
```

Expose port 8080 with a trusted webhook tunnel, set the App webhook URL to the
tunnel's `/webhooks/github` endpoint, and use GitHub's webhook-delivery page to
redeliver a pull-request event. A valid delivery returns HTTP 202 immediately;
analysis continues on the bounded in-memory worker.

The deterministic, network-free acceptance test uses the same signature and
orchestration code against a fake GitHub API:

```sh
make github-app-spike
```

## One private-installation smoke test

1. Install the App on one private test repository containing a Swift package.
2. Start the executable with the three required secrets and a public HTTPS
   webhook URL.
3. Open a PR that changes exactly one `Package.resolved`.
4. Confirm the delivery receives HTTP 202 and exactly one Check named
   `SwiftServe / Upgrade Receipt` appears on the PR head SHA.
5. Redeliver the same webhook and confirm that Check is updated, not duplicated.
6. Push a new commit and confirm a new logical Check uses the new head SHA.
7. Advance the PR's base branch and confirm the existing logical Check is
   refreshed against the new base SHA.

No credentials are committed by this workflow. The minimal setup needed for a
real smoke test is an App ID, one downloaded App private key, a matching webhook
secret, and installation of that App on the private test repository.

## Trust and failure behavior

- The HMAC-SHA256 signature is verified against raw bytes in constant time
  before JSON decoding. Missing, malformed, and invalid signatures are rejected.
- Lockfiles are fetched from the event's exact base and head commit SHAs. Added
  and removed lockfiles use an empty dependency set for the absent side; renamed
  lockfiles use `previous_filename` at the base SHA and the new path at the head.
- `.swiftserve.json` is fetched only from the exact base SHA. Only a genuine 404
  selects the default policy; malformed policy and every other failure close the
  Check as `failure`.
- More than one changed lockfile produces `action_required`; none produces
  `skipped`. The spike never silently selects the first lockfile.
- The worker re-reads the PR base ref, base SHA, and head SHA before publication.
  A stale worker publishes nothing over a newer result. Base-changing `edited`
  events and pushes to target branches trigger reprocessing.
- The stable external ID is derived from repository ID, PR number, and head SHA.
  Redelivery updates the matching Check; a new head creates a new logical Check.

## Cryptography dependency decision

The repository already resolved Apple `swift-crypto` 4.5.0 transitively through
Hummingbird. Before promotion to a direct dependency, `swiftserve scan --json
Package.resolved` confirmed the exact release pin, remote source, and clean
file-only hygiene signal (67 overall without live enrichment; hygiene 90).
The GitHub target uses its `Crypto` HMAC/SHA-256 and `CryptoExtras` RSA APIs for
the two interoperability requirements. This avoids a new JWT stack and avoids
implementing cryptographic primitives. No package resolution changed.
