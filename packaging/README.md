# Packaging

Launch-day distribution checklist and templates. Nothing here runs until the
repo is public and the first release is tagged.

## Order of operations

1. ~~Publish the repo~~ DONE 2026-07-02: public at nanoncore/swiftserve.
2. ~~Add a LICENSE file~~ DONE: FSL-1.1-ALv2 (fair source; converts to
   Apache-2.0 per release after 2 years). Licensor: Nanoncore.
3. Tag `v0.1.0` → `.github/workflows/release.yml` builds macOS-universal +
   Linux binaries, checksums them, and publishes the GitHub release.
4. Create the tap repo `<account>/homebrew-tap`, copy `swiftserve.rb` into
   `Formula/`, fill in the release URL + sha256 from `checksums.txt`.
5. Flip `GetPage.firstReleaseCut` to `true` and `make site` — the /get page
   switches from build-from-source to brew + installer.

## What points where

- `Public/install.sh` → GitHub latest release assets (`swiftserve-<tag>-<platform>.tar.gz`)
- `Formula/swiftserve.rb` (in the tap repo) → the same release tarballs
- `/plugin marketplace add <account>/swiftserve` → `.claude-plugin/marketplace.json` in this repo
- `https://swiftserve.dev/skill.md` → emitted by sitegen from `.claude/skills/swiftserve/SKILL.md`
