# ADR-0002: GRDB.swift (SQLite + FTS5) for persistence

**Status:** Accepted — 2026-11-09

## Context
Options: SwiftData (first-party, CloudKit-ready, opaque schema) vs. GRDB.swift (SQLite, explicit SQL migrations, FTS5).

## Decision
GRDB.swift. Schema is written as plain SQL migration files. Food search uses FTS5 with `unicode61 remove_diacritics 2`.

## Consequences
- Diacritic-insensitive, fast offline search for Croatian and English food names.
- Schema is readable and portable to Postgres for the phase-4 backend (no SQLite-only column types; FTS5 virtual table is replaced by a tsvector column there).
- One third-party dependency (MIT). CloudKit sync is not automatic; device-to-device sync, if wanted, is a separate task.
