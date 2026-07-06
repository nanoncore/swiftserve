# SwiftServe — build & install for local use + Claude Code.

BINDIR    ?= $(HOME)/.local/bin
SKILLDIR  ?= $(HOME)/.claude/skills/swiftserve
AGENTSDIR ?= $(HOME)/.agents/skills/swiftserve
BIN       := .build/release/swiftserve

.PHONY: help build install uninstall test livekit-spike recheck-spike

help:
	@echo "SwiftServe make targets:"
	@echo "  make build         Release-build the swiftserve CLI"
	@echo "  make install       Build + install swiftserve to $(BINDIR) and the Claude Code skill to $(SKILLDIR)"
	@echo "  make uninstall     Remove the installed binary and skill"
	@echo "  make test          Run the test suite"
	@echo "  make livekit-spike Fetch + extract the real LiveKit repos and show the noise-cancellation truth"
	@echo "  make recheck-spike Gate 'swiftserve index recheck' end-to-end against SwiftySound 1.2.0 → 1.3.0"
	@echo ""
	@echo "Override the bin location: make install BINDIR=/usr/local/bin"

build:
	swift build -c release

install: build
	@mkdir -p "$(BINDIR)" "$(SKILLDIR)" "$(AGENTSDIR)"
	install -m 0755 "$(BIN)" "$(BINDIR)/swiftserve"
	cp .claude/skills/swiftserve/SKILL.md "$(SKILLDIR)/SKILL.md"
	cp .claude/skills/swiftserve/SKILL.md "$(AGENTSDIR)/SKILL.md"
	@echo ""
	@echo "✅ swiftserve → $(BINDIR)/swiftserve"
	@echo "✅ skill      → $(SKILLDIR)/SKILL.md (Claude Code)"
	@echo "✅ skill      → $(AGENTSDIR)/SKILL.md (Codex & friends)"
	@echo ""
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "⚠️  Add to PATH:  export PATH=\"$(BINDIR):$$PATH\"" ;; esac
	@echo "Start a new Claude Code session, then try: \"check my dependency health\" or \"scan my app for private APIs\""

uninstall:
	rm -f "$(BINDIR)/swiftserve"
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
