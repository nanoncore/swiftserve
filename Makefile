# SwiftServe — build & install for local use + Claude Code.

BINDIR    ?= $(HOME)/.local/bin
SKILLDIR  ?= $(HOME)/.claude/skills/swiftserve
AGENTSDIR ?= $(HOME)/.agents/skills/swiftserve
BIN       := .build/release/swiftserve
RESOURCE_SUFFIX := $(if $(filter Darwin,$(shell uname -s)),bundle,resources)
CLI_RESOURCES := .build/release/SwiftServe_SwiftServeCLI.$(RESOURCE_SUFFIX)
EVIDENCE_RESOURCES := .build/release/SwiftServe_SwiftServeEvidence.$(RESOURCE_SUFFIX)

.PHONY: help build install uninstall test site-check livekit-spike recheck-spike receipt-spike github-app-spike github-app-mvp

help:
	@echo "SwiftServe make targets:"
	@echo "  make build         Release-build the swiftserve CLI"
	@echo "  make install       Build + install swiftserve to $(BINDIR) and the Claude Code skill to $(SKILLDIR)"
	@echo "  make uninstall     Remove the installed binary and skill"
	@echo "  make test          Run the test suite"
	@echo "  make site-check    Prove generated site files and all skill copies are synchronized"
	@echo "  make livekit-spike Fetch + extract the real LiveKit repos and show the noise-cancellation truth"
	@echo "  make recheck-spike Gate 'swiftserve index recheck' end-to-end against SwiftySound 1.2.0 → 1.3.0"
	@echo "  make receipt-spike Gate deterministic Upgrade Receipt JSON, Markdown, card, policy, and exit codes"
	@echo "  make github-app-spike Drive a signed PR webhook through the GitHub App against a fake API"
	@echo "  make github-app-mvp   Prove durable multi-lockfile processing, restart, retry, and idempotency"
	@echo ""
	@echo "Override the bin location: make install BINDIR=/usr/local/bin"

build:
	swift build -c release

install: build
	@mkdir -p "$(BINDIR)" "$(SKILLDIR)" "$(AGENTSDIR)"
	install -m 0755 "$(BIN)" "$(BINDIR)/swiftserve"
	cp -R "$(CLI_RESOURCES)" "$(BINDIR)/"
	cp -R "$(EVIDENCE_RESOURCES)" "$(BINDIR)/"
	cp .claude/skills/swiftserve/SKILL.md "$(SKILLDIR)/SKILL.md"
	cp .claude/skills/swiftserve/SKILL.md "$(AGENTSDIR)/SKILL.md"
	@echo ""
	@echo "✅ swiftserve → $(BINDIR)/swiftserve"
	@echo "✅ resources  → $(BINDIR)/SwiftServe_SwiftServe{CLI,Evidence}.$(RESOURCE_SUFFIX)"
	@echo "✅ skill      → $(SKILLDIR)/SKILL.md (Claude Code)"
	@echo "✅ skill      → $(AGENTSDIR)/SKILL.md (Codex & friends)"
	@echo ""
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "⚠️  Add to PATH:  export PATH=\"$(BINDIR):$$PATH\"" ;; esac
	@echo "Start a new Claude Code session, then try: \"check my dependency health\" or \"scan my app for private APIs\""

uninstall:
	rm -f "$(BINDIR)/swiftserve"
	rm -rf "$(BINDIR)/SwiftServe_SwiftServeCLI.$(RESOURCE_SUFFIX)"
	rm -rf "$(BINDIR)/SwiftServe_SwiftServeEvidence.$(RESOURCE_SUFFIX)"
	rm -rf "$(SKILLDIR)"
	@echo "Removed swiftserve and the SwiftServe skill."

test:
	swift test

# Regenerate the capability site into Public/ from validated records.
# Deterministic (no timestamp) so the diff is reviewable; browse it locally
# with `swift run SwiftServeServer` → http://127.0.0.1:8080
# Also syncs the canonical skill (.claude/skills/swiftserve) into the Claude
# Code plugin (plugins/swiftserve) and the open-standard skills dir
# (.agents/skills — what Codex and friends discover) so no copy ever drifts.
site:
	cp .claude/skills/swiftserve/SKILL.md plugins/swiftserve/skills/swiftserve/SKILL.md
	mkdir -p .agents/skills/swiftserve
	cp .claude/skills/swiftserve/SKILL.md .agents/skills/swiftserve/SKILL.md
	swift run SwiftServeSiteGen --records data/records --taxonomy data/taxonomy --out Public

SITE_CHECK := .build/site-check
site-check:
	rm -rf $(SITE_CHECK)
	mkdir -p $(SITE_CHECK)
	cp Public/styles.css Public/site.js Public/xr-entry.js Public/xr.js $(SITE_CHECK)/
	swift run SwiftServeSiteGen --records data/records --taxonomy data/taxonomy --out $(SITE_CHECK)
	@find $(SITE_CHECK) -type f | while IFS= read -r file; do rel=$${file#$(SITE_CHECK)/}; cmp "$$file" "Public/$$rel" || exit 1; done
	cmp .claude/skills/swiftserve/SKILL.md plugins/swiftserve/skills/swiftserve/SKILL.md
	cmp .claude/skills/swiftserve/SKILL.md .agents/skills/swiftserve/SKILL.md
	cmp .claude/skills/swiftserve/SKILL.md Public/skill.md
	@echo "✅ site-check: generated site and every SwiftServe skill copy are synchronized"

# Acceptance spike against the real LiveKit source (network + git): fetch at
# pinned tags, extract, and gate on the grounded verdicts. Note the live
# finding baked in here: at 2.15.1 the audio-SESSION gap is the true macOS
# unsupported (guarded os(iOS)||os(visionOS)||os(tvOS)); noise cancellation
# closed its macOS gap at Krisp 0.0.5 — capability truth changes, which is
# the product's whole argument.
livekit-spike:
	swift build
	.build/debug/swiftserve index fetch --package livekit --seeds-only
	.build/debug/swiftserve index extract --package livekit
	.build/debug/swiftserve capability-check livekit --capability audio.session-management --platform macos --card --expect unsupported
	.build/debug/swiftserve capability-check livekit --capability audio.session-management --platform ios --card --expect supported
	@echo "✅ livekit-spike: grounded verdicts hold against real source"

# Acceptance spike for the self-checking index (network + git): pin SwiftySound
# at the historical 1.2.0, recheck against the immutable 1.3.0. Gates: the
# report-only run is byte-for-byte side-effect free, --apply lands the bump
# (including the Sound line 65→62 auto-repair), a re-run reads up-to-date, and
# first-party records are skipped. Deterministic — both tags are history.
RECHECK_SPIKE := .build/recheck-spike
RECHECK_ARGS := --records $(RECHECK_SPIKE)/records --lock $(RECHECK_SPIKE)/lock.json --corpus-dir $(RECHECK_SPIKE)/corpus
recheck-spike:
	swift build
	rm -rf $(RECHECK_SPIKE)
	mkdir -p $(RECHECK_SPIKE)/records/audio
	.build/debug/swiftserve index fetch --package swiftysound --tag 1.2.0 --lock $(RECHECK_SPIKE)/lock.json --corpus-dir $(RECHECK_SPIKE)/corpus
	.build/debug/swiftserve index extract --package swiftysound --lock $(RECHECK_SPIKE)/lock.json --corpus-dir $(RECHECK_SPIKE)/corpus
	.build/debug/swiftserve index label-prep --package swiftysound --corpus-dir $(RECHECK_SPIKE)/corpus
	commit=$$(grep -o '[0-9a-f]\{40\}' $(RECHECK_SPIKE)/lock.json | head -1); \
	digest=$$(grep -o 'fnv1a64:[0-9a-f]*' $(RECHECK_SPIKE)/corpus/labeling/adamcichy__swiftysound/task.md | head -1); \
	sed -e "s/__COMMIT__/$$commit/" -e "s/__DIGEST__/$$digest/" Tests/Fixtures/recheck/swiftysound-1.2.0.template.json > $(RECHECK_SPIKE)/records/audio/adamcichy__swiftysound.json
	cp $(RECHECK_SPIKE)/records/audio/adamcichy__swiftysound.json $(RECHECK_SPIKE)/records-before.json
	cp $(RECHECK_SPIKE)/lock.json $(RECHECK_SPIKE)/lock-before.json
	.build/debug/swiftserve index recheck $(RECHECK_ARGS) --package swiftysound --tag 1.3.0 --out $(RECHECK_SPIKE)/report-1-dry.json
	grep -q '"outcome" : "still-true"' $(RECHECK_SPIKE)/report-1-dry.json
	@! grep -qE '"outcome" : "(truth-changed|anchor-gone|needs-probe)"' $(RECHECK_SPIKE)/report-1-dry.json
	grep -q '"change" : "line-repaired"' $(RECHECK_SPIKE)/report-1-dry.json
	cmp $(RECHECK_SPIKE)/records/audio/adamcichy__swiftysound.json $(RECHECK_SPIKE)/records-before.json
	cmp $(RECHECK_SPIKE)/lock.json $(RECHECK_SPIKE)/lock-before.json
	.build/debug/swiftserve index recheck $(RECHECK_ARGS) --package swiftysound --tag 1.3.0 --apply --out $(RECHECK_SPIKE)/report-2-apply.json
	grep -q '"applied" : true' $(RECHECK_SPIKE)/report-2-apply.json
	grep -q '"version" : "1.3.0"' $(RECHECK_SPIKE)/records/audio/adamcichy__swiftysound.json
	grep -q '"line" : 62' $(RECHECK_SPIKE)/records/audio/adamcichy__swiftysound.json
	.build/debug/swiftserve index recheck $(RECHECK_ARGS) --package swiftysound --tag 1.3.0 --out $(RECHECK_SPIKE)/report-3-again.json
	grep -q '"status" : "up-to-date"' $(RECHECK_SPIKE)/report-3-again.json
	cp data/records/audio/developer.apple.com__documentation__avfaudio.json $(RECHECK_SPIKE)/records/audio/
	.build/debug/swiftserve index recheck $(RECHECK_ARGS) --package avfaudio --out $(RECHECK_SPIKE)/report-4-sdk.json
	grep -q '"skipReason" : "first-party"' $(RECHECK_SPIKE)/report-4-sdk.json
	@echo "✅ recheck-spike: report-only is side-effect free, --apply lands the bump, repairs hold, SDKs skip"

# Deterministic, network-free Upgrade Receipt acceptance. The fixtures model an
# immutable v2 → v3 lockfile history and outputs stay under .build only.
RECEIPT_SPIKE := .build/receipt-spike
RECEIPT_BASE := Tests/Fixtures/receipt/base-v2.json
RECEIPT_HEAD := Tests/Fixtures/receipt/head-v3.json
RECEIPT_ENV := SWIFTSERVE_GENERATED_AT=2026-08-05T12:00:00Z NO_COLOR=1
receipt-spike:
	swift build
	rm -rf $(RECEIPT_SPIKE)
	mkdir -p $(RECEIPT_SPIKE)
	cp $(RECEIPT_BASE) $(RECEIPT_SPIKE)/base-before.json
	cp $(RECEIPT_HEAD) $(RECEIPT_SPIKE)/head-before.json
	$(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --json --file-only --fail-on block > $(RECEIPT_SPIKE)/receipt.json
	grep -q '"receiptVersion" : 1' $(RECEIPT_SPIKE)/receipt.json
	grep -q '"verdict" : "review"' $(RECEIPT_SPIKE)/receipt.json
	$(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --markdown --file-only --fail-on block > $(RECEIPT_SPIKE)/receipt.md
	grep -q 'Upgrade Receipt — REVIEW' $(RECEIPT_SPIKE)/receipt.md
	$(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --card --file-only --fail-on block > $(RECEIPT_SPIKE)/receipt.card
	grep -q 'Upgrade Receipt — REVIEW' $(RECEIPT_SPIKE)/receipt.card
	@set +e; $(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --json --file-only --fail-on review >/dev/null; code=$$?; set -e; test $$code -eq 1
	@set +e; $(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --json --file-only --policy Tests/Fixtures/receipt/block-major-policy.json >/dev/null; code=$$?; set -e; test $$code -eq 1
	@set +e; $(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_BASE) --json --file-only --policy Tests/Fixtures/receipt/required-capability-block-policy.json >$(RECEIPT_SPIKE)/required-block.json; code=$$?; set -e; test $$code -eq 1
	grep -q '"headline" : "No dependency changes detected; blocked by policy."' $(RECEIPT_SPIKE)/required-block.json
	grep -q 'required-capability-unverified:demo:audio.demo:macOS' $(RECEIPT_SPIKE)/required-block.json
	@set +e; $(RECEIPT_ENV) .build/debug/swiftserve diff Tests/Fixtures/receipt/malformed.json $(RECEIPT_HEAD) --json --file-only >$(RECEIPT_SPIKE)/bad.stdout 2>$(RECEIPT_SPIKE)/bad.stderr; code=$$?; set -e; test $$code -eq 2
	test ! -s $(RECEIPT_SPIKE)/bad.stdout
	grep -q '"error"' $(RECEIPT_SPIKE)/bad.stderr
	@set +e; .build/debug/swiftserve diff $(RECEIPT_BASE) --json >$(RECEIPT_SPIKE)/missing.stdout 2>$(RECEIPT_SPIKE)/missing.stderr; code=$$?; set -e; test $$code -eq 2
	test ! -s $(RECEIPT_SPIKE)/missing.stdout
	grep -q '"error"' $(RECEIPT_SPIKE)/missing.stderr
	@set +e; .build/debug/swiftserve diff $(RECEIPT_BASE) $(RECEIPT_HEAD) --json --fail-on nope >$(RECEIPT_SPIKE)/invalid-option.stdout 2>$(RECEIPT_SPIKE)/invalid-option.stderr; code=$$?; set -e; test $$code -eq 2
	test ! -s $(RECEIPT_SPIKE)/invalid-option.stdout
	grep -q '"error"' $(RECEIPT_SPIKE)/invalid-option.stderr
	cmp $(RECEIPT_BASE) $(RECEIPT_SPIKE)/base-before.json
	cmp $(RECEIPT_HEAD) $(RECEIPT_SPIKE)/head-before.json
	git show HEAD:Tests/SwiftServeCoreTests/Fixtures/resolved-v2.json > $(RECEIPT_SPIKE)/workflow-base.resolved
	cp Tests/SwiftServeCoreTests/Fixtures/resolved-v2.json $(RECEIPT_SPIKE)/workflow-head.resolved
	GITHUB_STEP_SUMMARY=$(RECEIPT_SPIKE)/step-summary.md $(RECEIPT_ENV) .build/debug/swiftserve diff $(RECEIPT_SPIKE)/workflow-base.resolved $(RECEIPT_SPIKE)/workflow-head.resolved --markdown --file-only --fail-on block >> $(RECEIPT_SPIKE)/step-summary.md
	grep -q 'Upgrade Receipt — PASS' $(RECEIPT_SPIKE)/step-summary.md
	sh Tests/Shell/install-checksum-fallback.sh
	sh Tests/Shell/staged-release-resources.sh .build/debug
	grep -q -- '- "Package.resolved"' docs/examples/upgrade-receipt.yml
	@if grep -q '\*\*/Package.resolved' docs/examples/upgrade-receipt.yml; then exit 1; fi
	@echo "✅ receipt-spike: deterministic v2/v3 receipt, renderers, policies, clean stdout, and exit codes 0/1/2"

# Network-free GitHub App acceptance. The focused test signs a pull_request
# webhook, passes it through the real webhook/orchestration layers, serves all
# immutable GitHub inputs from a protocol fake, and asserts exactly one Check.
github-app-spike:
	swift test --filter GitHubAppAcceptanceTests
	@echo "✅ github-app-spike: one signed dependency PR publishes one correctly mapped Check"

# Production-MVP acceptance remains network-free and deterministic. It commits a
# signed multi-lockfile delivery to SQLite, reconstructs the service as if after
# a crash, reschedules a simulated primary rate-limit response without sleeping
# a worker, completes one aggregate Check, and proves redelivery is idempotent.
github-app-mvp:
	swift test --filter durableMVP
	@echo "✅ github-app-mvp: durable restart + rate-limit retry completes one aggregate Check"
