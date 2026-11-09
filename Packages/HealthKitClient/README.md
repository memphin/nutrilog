# HealthKitClient

Apple Health access behind a protocol, so the app, its tests and previews never need real Health data.

- `HealthDataSource` — the protocol: availability, authorization (request status, permission sheet, write status), daily data fetch for a range of local days, profile characteristics.
- `LiveHealthDataSource` — `HKHealthStore` implementation (iOS only, `#if os(iOS)`): daily statistics collection queries for steps / energy / water, sample queries for weight, body fat, resting HR, HRV and sleep.
- `FakeHealthDataSource` — in-memory implementation for tests and previews; `.demo(endingOn:)` gives plausible data.
- `HealthReadType` / `HealthWriteType` — the type catalog with the onboarding explanation of each type.

The per-day rules (day boundaries, earliest weigh-in, overnight HRV, sleep windows and source priority) live in Core (`DailyMetricsAggregator`, `SleepAggregator`), so they are tested on macOS with fixed time zones.

Read access is opaque in HealthKit: a denied type returns no data. Show `HealthKitClient.noDataMessage` ("No data found — check Health permissions") instead of assuming a denial.

Not here yet: observer queries / background delivery (backlog #26) and writing to Health (#27) — add them as separate protocols next to `HealthDataSource`.

Run tests: `cd Packages/HealthKitClient && swift test` (macOS; the live HealthKit code is compiled by the app build).
