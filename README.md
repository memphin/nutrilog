# Nutrilog

**A free, ad-free, open-source, privacy-first nutrition & health tracker for iOS.**

Log what you eat (barcode scan, search, recipes, saved meals) and see it next to how your body responds — weight trend, body fat, steps, sleep, resting heart rate, HRV — all pulled from Apple Health. No account, no cloud, no telemetry.

> Status: **Phase 0 — project foundation.** The app launches but has no features yet. See the [roadmap](docs/SPEC.md#13-roadmap).

## Features (planned for v1)

- Fast food diary with meal slots, recents, favorites, saved meals and recipes
- Barcode scanning (VisionKit) with Open Food Facts lookup and one-tap manual entry when a product is missing
- Offline search over a bundled USDA FoodData Central subset + your own foods (SQLite FTS5, diacritic-insensitive)
- Calorie and macro targets, **adaptive TDEE estimate** from your intake and smoothed weight trend, weekly check-in
- Apple Health: reads steps, sleep (with stages), weight, body fat %, active energy, resting HR, HRV, water; writes nutrients and water
- Works with any scale/watch that syncs to Apple Health (built and tested with a Withings scale + Apple Watch)
- Charts, weekly report, JSON/CSV export — your data is always yours

Not planned: ads, subscriptions, social features, coaching, analytics SDKs.

## Requirements

- iOS 26.0+
- Xcode 26+, Swift 6
- An Apple Developer Program membership for HealthKit background delivery on a device (free accounts can build, but builds expire after 7 days)

## Build

```bash
git clone https://github.com/memphin/nutrilog.git
cd nutrilog
cp Config/Secrets.xcconfig.template Config/Secrets.xcconfig   # optional: USDA key, Team ID
open Nutrilog.xcodeproj
```

1. Put your Apple Developer Team ID in `Config/Secrets.xcconfig` (`DEVELOPMENT_TEAM = ...`) or pick your team in Xcode → `Nutrilog` target → Signing & Capabilities.
2. HealthKit (with *Background Delivery*) is already declared in `App/Nutrilog.entitlements`.
3. Run on a real iPhone (HealthKit is limited in the simulator). Simulator builds and tests work without a team.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing targets, files or settings: `brew install xcodegen && xcodegen generate`, and commit both `project.yml` and `Nutrilog.xcodeproj`.

Tests: `xcodebuild test -project Nutrilog.xcodeproj -scheme Nutrilog -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO`, or `swift test` inside any `Packages/<name>`.

### Optional: USDA FoodData Central key

The app works without one (bundled foods + Open Food Facts). For online USDA search either paste a free key in **Settings → Food sources** (stored in Keychain) or put it in `Config/Secrets.xcconfig` (git-ignored). Never commit a key — USDA deactivates keys found in public repos.

## Project layout

```
App/            SwiftUI app, DI, navigation
Packages/       Swift packages: Core, Persistence (GRDB), FoodSources, HealthKitClient, Scanner, DesignSystem
Widgets/        WidgetKit extension (post-v1)
Intents/        App Intents (Siri / Shortcuts)
Resources/      Bundled food index, licenses
tools/          Scripts (e.g. build the bundled USDA food index)
docs/           SPEC.md (product & technical specification), ADRs
```

## Data sources & attribution

- **Open Food Facts** — packaged products by barcode. © Open Food Facts contributors, [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/). Product data is cached on-device only and never committed to this repository.
- **USDA FoodData Central** — generic foods. Public domain (CC0 1.0). A curated subset is bundled with the app.
- **Apple HealthKit** — your own health data, on-device.

## Privacy

See [PRIVACY.md](PRIVACY.md). Short version: the only network calls are to Open Food Facts and (optionally) USDA. Nothing else leaves your phone.

## Contributing

Issues and PRs welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) first. This is a personal project built in spare time; response times vary.

## License

Code: [MIT](LICENSE). Bundled datasets keep their own licenses (see above).

*Nutrilog is not a medical device and provides no medical advice.*
