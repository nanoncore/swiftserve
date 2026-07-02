# SwiftServe — build & install for local use + Claude Code.

BINDIR   ?= $(HOME)/.local/bin
SKILLDIR ?= $(HOME)/.claude/skills/swiftserve
BIN      := .build/release/swiftserve

.PHONY: help build install uninstall test livekit-spike

help:
	@echo "SwiftServe make targets:"
	@echo "  make build         Release-build the swiftserve CLI"
	@echo "  make install       Build + install swiftserve to $(BINDIR) and the Claude Code skill to $(SKILLDIR)"
	@echo "  make uninstall     Remove the installed binary and skill"
	@echo "  make test          Run the test suite"
	@echo "  make livekit-spike Fetch + extract the real LiveKit repos and show the noise-cancellation truth"
	@echo ""
	@echo "Override the bin location: make install BINDIR=/usr/local/bin"

build:
	swift build -c release

install: build
	@mkdir -p "$(BINDIR)" "$(SKILLDIR)"
	install -m 0755 "$(BIN)" "$(BINDIR)/swiftserve"
	cp .claude/skills/swiftserve/SKILL.md "$(SKILLDIR)/SKILL.md"
	@echo ""
	@echo "✅ swiftserve → $(BINDIR)/swiftserve"
	@echo "✅ skill      → $(SKILLDIR)/SKILL.md"
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
# Code plugin (plugins/swiftserve) so the two copies never drift.
site:
	cp .claude/skills/swiftserve/SKILL.md plugins/swiftserve/skills/swiftserve/SKILL.md
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
