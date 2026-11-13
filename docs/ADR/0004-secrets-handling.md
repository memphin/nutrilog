# ADR-0004: No secrets in the repository

**Status:** Accepted — 2026-11-09

## Context
Public GitHub repo. USDA FoodData Central deactivates API keys found online. Open Food Facts needs no key.

## Decision
The optional USDA key is supplied only at build time, never committed and never entered in the app (the earlier Settings/Keychain option was removed after 1.2.0):
1. `Config/Secrets.xcconfig` (git-ignored) → injected at build; CI uses a repository secret.
2. Phase 4: backend proxy holds the key.

`gitleaks` runs on every push. The app must be fully functional with no key (bundled USDA subset + OFF).

## Consequences
- Forks work out of the box.
- CI build for PRs uses a placeholder xcconfig; online USDA search is simply unavailable in those builds.
