# Persistence

GRDB.swift-based SQLite store. Schema lives in plain SQL files under `Sources/Persistence/Migrations/` so it can be reviewed, diffed, and mirrored to Postgres in phase 4.

- `AppDatabase` — opens the pool (WAL, foreign keys, Data Protection) and runs migrations.
- `Migrator` — ordered list of migration files.
- `Migrations/001_initial.sql` — schema v1 (see `docs/SPEC.md` §8).

Rules: see `CONTRIBUTING.md` → *Database changes*.

Run tests: `cd Packages/Persistence && swift test`
