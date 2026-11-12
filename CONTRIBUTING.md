# Contributing

Thanks for your interest. Vitalion is a personal, spare-time project — contributions are welcome but please read this first.

## Ground rules
- The product scope is defined in [docs/SPEC.md](docs/SPEC.md). Features outside it (ads, accounts, social, analytics) will not be accepted. Propose scope changes as an issue first.
- Privacy is non-negotiable: no new network destinations, no telemetry, no third-party SDKs that make network calls.
- Target is iOS 26+, Swift 6 strict concurrency, SwiftUI. No UIKit unless wrapping a system API (e.g. VisionKit).
- Dependencies: GRDB.swift only, unless an issue approves another MIT/Apache/BSD package.

## Workflow
1. Open or pick an issue. Comment that you are working on it.
2. Branch from `main`: `feature/<short-name>` or `fix/<short-name>`.
3. Keep PRs small and focused. One feature or fix per PR.
4. Add/adjust unit tests in the affected package (Core requires tests for all nutrient/TDEE/date math).
5. Run `xcodebuild test` locally (or let CI do it) — CI must be green.
6. Fill in the PR template. PRs are squash-merged.

## Code style
- SwiftFormat/SwiftLint configs will be added in Phase 0; until then follow the Swift API Design Guidelines.
- Prefer value types, `actor`s for shared mutable state, `async/await` for I/O.
- Persisted models live in `Packages/Persistence`; domain logic in `Packages/Core` (pure Swift, no Foundation networking, no HealthKit).

## Localization (English + Croatian)
- The UI is English with a Croatian translation, in String Catalogs: `App/Resources/*.xcstrings`, `Widgets/Localizable.xcstrings` and `Packages/<Name>/Sources/<Name>/Localizable.xcstrings`. The language follows iOS (Settings → Vitalion → Language); there is no in-app switch.
- SwiftUI literals (`Text("Save")`) are localized automatically. Any other `String` shown to the user goes through `String(localized: "…")` (in a package: `bundle: .module`). Counts are one interpolated `Int` (`String(localized: "\(count) foods")`) with plural forms in the catalog, never `count == 1 ? … : …`; Croatian has three forms (1, 2–4, 5+).
- Numbers and dates on screen use the current locale (`FormatStyle`), never `String(format:)` or a fixed `en_US`.
- New strings land in the catalogs when you build in Xcode, or run `xcodebuild -exportLocalizations -project Vitalion.xcodeproj -scheme Vitalion -localizationPath /tmp/loc -exportLanguage hr`. Add the Croatian (informal "ti") in Xcode's catalog editor, or write a JSON file and apply it with `tools/apply_translations.py <catalog> <translations.json>`. CI fails when a key has no Croatian.
- Bundled food names: `tools/food_names_hr.csv` (see `tools/README.md`).

## Database changes
- Never edit an existing migration. Add a new numbered file in `Packages/Persistence/Sources/Persistence/Migrations/` and register it in `Migrator.swift`.
- Keep SQL portable (SQLite ⇄ Postgres): no SQLite-only column types, use `TEXT` ISO-8601 for dates, `TEXT` UUIDs, `INTEGER` 0/1 for booleans.
- Every table has `created_at`, `updated_at`, `deleted_at`, `revision` (see ADR-0003).

## Secrets
Never commit API keys, provisioning profiles or `Config/Secrets.xcconfig`. CI runs gitleaks; a leaked USDA key is deactivated by USDA automatically.

## Reporting bugs
Use the bug template. Include iOS version, device, steps, and an export (with personal data removed) if relevant.
