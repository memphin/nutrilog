# Persistence

GRDB.swift-based SQLite store. Schema lives in plain SQL files under `Sources/Persistence/Migrations/` so it can be reviewed, diffed, and mirrored to Postgres in phase 4.

- `AppDatabase` — opens the pool (WAL, foreign keys, Data Protection) and runs migrations.
- `Migrator` — ordered list of migration files.
- `Migrations/001_initial.sql` — schema v1 (see `docs/SPEC.md` §8).
- `OFFProductCache` — raw store for `off_product_cache` (OFF product JSON or a not-found marker per barcode). The
  freshness rules live in `FoodLookup.BarcodeLookup`; the table is a cache and is not exported.
- Repositories: `FoodRepository`, `DiaryRepository`, `ProfileRepository`, `DailyMetricsRepository` (the `daily_metrics` cache of Apple Health), `WaterRepository` (`water_entry`), `HealthKitLinkRepository` (`healthkit_link` + the `healthkit_outbox` queue of rows to mirror to Apple Health; `DiaryRepository` and `WaterRepository` queue every change in the same transaction).
- `Migrations/005_healthkit_outbox.sql` — the Health write queue (backlog #27).

Rules: see `CONTRIBUTING.md` → *Database changes*.

Run tests: `cd Packages/Persistence && swift test`
