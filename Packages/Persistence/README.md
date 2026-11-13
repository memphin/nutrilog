# Persistence

GRDB.swift-based SQLite store. Schema lives in plain SQL files under `Sources/Persistence/Migrations/` so it can be reviewed, diffed, and mirrored to Postgres in phase 4.

- `AppDatabase` — opens the pool (WAL, foreign keys, Data Protection) and runs migrations.
- `Migrator` — ordered list of migrations: numbered SQL files in `Sources/Persistence/Migrations/` (schema v1 is `001_initial.sql`, see `docs/SPEC.md` §8), plus migrations written in code in `Migrator.swift` (011 and 014).
- `OFFProductCache` — raw store for `off_product_cache` (OFF product JSON or a not-found marker per barcode). The
  freshness rules live in `FoodLookup.BarcodeLookup`; the table is a cache and is not exported.
- `FoodSearch` — offline search over the bundled food index and your own foods (FTS5).
- Repositories: `FoodRepository`, `DiaryRepository`, `MealTemplateRepository`, `MealPlanRepository`, `ProfileRepository`, `CheckInRepository`, `DailyMetricsRepository` (the `daily_metrics` cache of Apple Health), `WaterRepository`, `HydrationRepository`, `CaffeineRepository`, `WeightRepository`, `TrainingDayRepository`, `HealthKitLinkRepository` (`healthkit_link` + the `healthkit_outbox` queue of rows to mirror to Apple Health; changes are queued in the same transaction).
- `DataPortability` (JSON/CSV export and import) and `LocalBackups` (weekly on-device backups).

Rules: see `CONTRIBUTING.md` → *Database changes*.

Run tests: `cd Packages/Persistence && swift test`
