# ADR-0003: Sync-ready schema from day one, no backend in v1

**Status:** Accepted — 2026-11-09

## Context
v1 is local-only. Phase 4 adds a self-hosted backend (Supabase or PocketBase) and a web client. Retrofitting sync onto a schema is painful.

## Decision
Every user-data table carries: `id TEXT` (UUID v4), `created_at`, `updated_at` (ISO-8601 UTC), `deleted_at` (soft delete) and `revision INTEGER`. Deletes are soft. `diary_entry` stores a nutrient snapshot so history never depends on the current food record. `daily_metrics` is a cache of Apple Health and is written only by the iOS app.

Sync protocol (phase 4): pull rows with `updated_at > last_sync`; push dirty rows; last-writer-wins by `updated_at`, with `revision` used to detect conflicts for diary entries (both kept and flagged).

## Consequences
- Slight overhead per row now; trivial sync later.
- Queries must filter `deleted_at IS NULL`; a periodic purge of tombstones (older than 90 days once synced, or 30 days in local-only mode) was planned but is **not implemented**; it is deferred to the sync phase.
