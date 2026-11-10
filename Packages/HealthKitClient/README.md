# HealthKitClient

Apple Health access behind protocols, so the app, its tests and previews never need real Health data.

- `HealthDataSource` — reading: availability, authorization (request status, permission sheet, write status), daily data fetch for a range of local days, profile characteristics.
- `HealthObserving` — observer queries + hourly background delivery for every metric type (backlog #26). Pass the updates to a `HealthObserverDispatcher`, which coalesces bursts into one refresh and **always** calls HealthKit's completion handler (on success, observer errors, a hung refresh via a timeout, and after `stop()`).
- `HealthWriting` — writing Vitalion's own entries (backlog #27): `save` drafts, `deleteSamples(externalID:types:)`. Samples carry `HKMetadataKeyExternalUUID` = the row id, a sync identifier `<row id>.<type>` and the row revision as sync version; `HealthSamples` builds the drafts for diary entries (energy, protein, carbs, fat, fiber, sugar, sodium) and water.
- `LiveHealthDataSource` — `HKHealthStore` implementation of all three (iOS only, `#if os(iOS)`): daily statistics collection queries for steps / energy / water, sample queries for weight, body fat, resting HR, HRV and sleep, observer queries, saving and deleting own samples.
- `FakeHealthDataSource`, `FakeHealthObserver`, `FakeHealthWriter` — in-memory implementations for tests and previews; `FakeHealthDataSource.demo(endingOn:)` gives plausible data, `FakeHealthObserver.fire(_:)` plays an observer callback and returns its completion, `FakeHealthWriter(mirror:)` makes written water readable again.
- `HealthReadType` / `HealthWriteType` — the type catalog with the onboarding explanation of each type.

The per-day rules (day boundaries, earliest weigh-in, overnight HRV, sleep windows and source priority, leaving Vitalion's own water out of the water read back) live in Core (`DailyMetricsAggregator`, `SleepAggregator`), so they are tested on macOS with fixed time zones.

Read access is opaque in HealthKit: a denied type returns no data. Show `HealthKitClient.noDataMessage` ("No data found — check Health permissions") instead of assuming a denial.

Run tests: `cd Packages/HealthKitClient && swift test` (macOS; the live HealthKit code is compiled by the app build).
