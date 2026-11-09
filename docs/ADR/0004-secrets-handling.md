# ADR-0004: No secrets in the repository

**Status:** Accepted — 2026-11-09

## Context
Public GitHub repo. USDA FoodData Central deactivates API keys found online. Open Food Facts needs no key.

## Decision
Three supported ways to supply the optional USDA key, none committed:
1. User pastes a key in Settings → stored in Keychain (default for forks).
2. `Config/Secrets.xcconfig` (git-ignored) → injected at build; CI uses a repository secret.
3. Phase 4: backend proxy holds the key.

`gitleaks` runs on every push. The app must be fully functional with no key (bundled USDA subset + OFF).

## Consequences
- Forks work out of the box.
- CI build for PRs uses a placeholder xcconfig; online USDA search is simply unavailable in those builds.
