# Hydration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Water tile with Hydration: every drink counts, a timeline shows when you drank and where the
gaps are, the goal follows body weight, and reminders fire on gaps or falling behind pace.

**Architecture:** Each drink's volume is snapshotted at log time (`diary_entry.fluid_ml`, `caffeine_entry.ml`,
`water_entry.ml`). A pure Core module (`Hydration.swift`) turns a day's `FluidIntake`s plus settings into totals,
pace, gaps, status and the next reminder. Persistence merges the three sources into one observation; the app
renders the tile strip, the detail chart, settings, and schedules one local notification.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Charts, GRDB, Swift Testing, UserNotifications,
XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-11-hydration-design.md`

## Global Constraints

- iOS 26.0, Swift 6.0, `SWIFT_STRICT_CONCURRENCY: complete`; no new dependencies, no network destinations (CONTRIBUTING).
- Never edit a shipped migration; add `013_hydration.sql` (schema + SQL backfills) and `014_caffeine_ml` (Swift-coded) and register both in `Migrator.migrations`.
- New App files: run `xcodegen generate` and commit `Vitalion.xcodeproj` with them.
- User-facing name is "Hydration"; the enum case `DashboardTile.water`, table `water_entry`, column `water_goal_ml` and `SettingKey.waterQuickAddSizes` keep their names (stored layouts and data depend on them).
- Only plain water is written to Apple Health; do not touch `HealthWriteService` water behaviour.
- Constants: 30 ml/kg, round to 50 ml, fallback goal 2500 ml; fat cut-off 50 g/100; fallback wake 07:00 (420 min); gap 180 min (60–360, step 30); behind margin 500 ml (250–1000, step 50); pace reaches goal at bedtime − 60 min; reminders off by default; notification id `hydration-reminder`, category `HYDRATION`, action `HYDRATION_ADD`.
- Copy (exact): gap title "Time for a drink", body "No drink since {HH:mm} · {total} of {goal} ml"; behind title "You're behind on hydration", body "{total} ml so far — about {expected} by now keeps you on track"; action "+ {smallest size} ml".
- Package tests: `cd Packages/<Pkg> && swift test --filter <Suite>`. App tests: `cp -n Config/Secrets.xcconfig.template Config/Secrets.xcconfig; xcodebuild test -project Vitalion.xcodeproj -scheme Vitalion -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VitalionTests/<Suite> -quiet`.
- Commit after each task; messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Diary entry logged from a *meal plan* (`MealPlanRepository` "mark eaten") or a *saved meal* (`logAll`) — must get `fluid_ml` like a single log (Task 4 tests both).
2. A food that is liquid but switched off, or solid but switched on, edited *after* entries exist — old entries keep their `fluid_ml` (Task 4 test).
3. Wake time later than bedtime − 1 h (night shift, bad sleep data) — no crash, no gaps, no pace, no reminder for today (Task 1 tests).
4. Reminder recompute when reminders are on but notification permission was revoked in iOS Settings — pending request removed, no throw (Task 9 test).
5. Day rollover at midnight while the app stays open — tile and reminder switch to the new day (Task 6 / Task 9 tests use an injected clock across midnight).

---

### Task 1: Core hydration model

**Files:**
- Create: `Packages/Core/Sources/Core/Hydration.swift`
- Test: `Packages/Core/Tests/CoreTests/HydrationTests.swift`

**Interfaces:**
- Produces:
  - `public struct FluidIntake: Hashable, Sendable, Identifiable { id: String; ml: Double; at: Date; kind: Kind; source: Source; name: String; enum Kind { case water, other }; enum Source { case water, diary, caffeine } }`
  - `public enum FluidRule { static let maxFatPer100 = 50.0; static func counts(isLiquid: Bool, fatPer100: Double, override: Bool?) -> Bool }`
  - `public enum HydrationGoalMode: String, Codable, Sendable { case weight, fixed }`
  - `public enum HydrationGoal { static let mlPerKg = 30.0; static let fallbackMl = 2500.0; static func ml(weightKg: Double?, mode: HydrationGoalMode, fixedMl: Double) -> Double }`
  - `public struct HydrationDay: Sendable` with `init(intakes: [FluidIntake], otherAppsMl: Double, goalMl: Double, wake: Date, bedtime: Date, gapThreshold: TimeInterval, behindMarginMl: Double, now: Date)`; properties `totalMl, waterMl, otherDrinksMl, otherAppsMl: Double`, `steps: [(at: Date, totalMl: Double)]` (timed intakes only, cumulative), `paceEnd: Date` (= bedtime − 3600), `isWindowValid: Bool`, `func pace(at: Date) -> Double?`, `gaps: [HydrationGap]`, `status: HydrationStatus`, `lastIntakeAt: Date?`
  - `public struct HydrationGap: Hashable, Sendable { start: Date; end: Date; isOngoing: Bool }`
  - `public enum HydrationStatus: Sendable { case goalReached, inGap(since: Date), behind(byMl: Double), onPace }`
  - `public enum HydrationReminder { struct Plan: Hashable, Sendable { date: Date; reason: Reason }; enum Reason: Hashable, Sendable { case gap(since: Date), behind(expectedMl: Double) }; static func next(day: HydrationDay, tomorrowWake: Date) -> Plan? }`

- [ ] **Step 1: Write failing tests** in `HydrationTests.swift` (Swift Testing, `@Suite struct HydrationTests`). Fixture: wake 07:00, bedtime 23:00, goal 2400, gap 3 h, margin 500, fixed UTC calendar. Tests and assertions:
  - `totalsSplitByKind`: water 250 + 500, diary 330 (other), caffeine 240 (other), otherApps 200 → `totalMl == 1520`, `waterMl == 750`, `otherDrinksMl == 570`, `otherAppsMl == 200`.
  - `paceIsLinearToBedtimeMinusOneHour`: `pace(at: 07:00) == 0`, `pace(at: 14:30) == 1200`, `pace(at: 22:00) == 2400`, `pace(at: 22:45) == 2400`, `pace(at: 06:00) == 0`.
  - `gapsBetweenDrinksAndOngoing`: intakes 07:30, 08:15, 10:00, 12:30, 13:00, now 17:00 → `gaps == [13:00–17:00 ongoing]`; with a drink at 17:30 and now 18:00 → one closed gap 13:00–17:30.
  - `gapFromWakeWhenNoDrinks`: no intakes, now 10:30 → one ongoing gap 07:00–10:30; now 09:59 → none.
  - `gapExactlyAtThresholdIsNotAGap`: drinks 08:00 and 11:00 → no gap.
  - `nightAndOutOfWindowDrinksDontMakeGaps`: drink 02:00 counts in `totalMl`, `gaps` start at 07:00.
  - `statusPrecedence`: total ≥ goal → `.goalReached` even in a gap; ongoing gap → `.inGap(since:)`; 600 below pace without gap → `.behind(byMl: 600)`; else `.onPace`.
  - `invalidWindow`: wake 22:30 → `isWindowValid == false`, `pace(at:) == nil`, `gaps.isEmpty`, `HydrationReminder.next == tomorrow plan`.
  - `reminderGapWins`: drinks totalling 2000 ml, last at 13:00, now 14:00 (total + margin ≥ goal, so no behind candidate) → `.gap(since: 13:00)` at 16:00.
  - `reminderBehindWins`: one drink of 100 ml at 09:00, now 09:30 → behind time = 07:00 + (100+500)/2400 · 15 h = 10:45, gap time 12:00 → plan at 10:45, `.behind(expectedMl: 600)`.
  - `noReminderWhenGoalReached` → nil.
  - `reminderAfterPaceEndRollsToTomorrow`: drinks totalling 2000 ml, last at 20:30, now 21:00 → gap 23:30 > 22:00 and behind beyond paceEnd → plan at `tomorrowWake + 3 h`, reason `.gap(since: tomorrowWake)`.
  - `reminderNeverInThePast`: no drinks, now 10:20 (gap time 10:00 already passed) → plan date == now, `.gap(since: 07:00)`.
  - `fluidRule`: (liquid, fat 0, nil) → true; (liquid, fat 91, nil) → false; (solid, 0, nil) → false; (solid, 0, true) → true; (liquid, 0, false) → false.
  - `goalFromWeight`: 80 kg → 2400; 73 kg → 2200 (2190 rounds to 2200); nil → 2500; fixed mode 1800 ignores weight → 1800.
- [ ] **Step 2: Run** `cd Packages/Core && swift test --filter HydrationTests` → FAIL (types missing).
- [ ] **Step 3: Implement** `Hydration.swift`. Window valid iff `wake < paceEnd`. Gaps: walk sorted timed intakes with `at` in `[wake, min(now, bedtime)]`, boundaries wake → each → `min(now, bedtime)` (last one `isOngoing` when it ends at `now`), keep intervals `> gapThreshold`. Behind time solved analytically: `t = wake + (totalMl + margin) / goalMl · (paceEnd − wake)`, only if `totalMl + margin < goalMl`. `next`: nil if `totalMl ≥ goalMl`; candidates gap = `max(lastIntakeAt ?? wake, wake) + threshold`, behind as above; take earliest candidate ≤ paceEnd, clamped to ≥ now; else tomorrow plan. Doc comments in the style of `Caffeine.swift`.
- [ ] **Step 4: Run** the same command → PASS; also `swift test` for whole Core → PASS.
- [ ] **Step 5: Commit** `Core: hydration model (intakes, pace, gaps, goal, reminder plan)`.

### Task 2: Wake-up time from sleep

**Files:**
- Modify: `Packages/Core/Sources/Core/SleepAggregator.swift` (`SleepSummary`, `measure`)
- Modify: `Packages/Core/Sources/Core/DailyMetricsAggregator.swift` (`wokeAt`, `apply(sleep:)`)
- Test: `Packages/Core/Tests/CoreTests/SleepAggregatorTests.swift` (existing file; add tests)

**Interfaces:**
- Produces: `SleepSummary.wokeAt: Date?`; `DailyMetrics.wokeAt: Date?` (set by `apply(sleep:)`).

- [ ] **Step 1: Failing tests:** `wokeAtIsEndOfLastAsleepSampleBeforeNoon` (asleep 23:00–06:40, awake 06:40–06:50 → `wokeAt == 06:40`); `afternoonNapDoesNotMoveWokeAt` (plus nap 14:00–14:30 → still 06:40); `noAsleepSamplesMeansNilWokeAt` (inBed only → nil); `applySleepCopiesWokeAt`.
- [ ] **Step 2: Run** `cd Packages/Core && swift test --filter SleepAggregatorTests` → FAIL.
- [ ] **Step 3: Implement:** in `measure`, `wokeAt = samples.filter { $0.stage.isAsleep && $0.end <= night.date(atHour: 12, calendar:) }.map(\.end).max()` (pass `calendar` into `measure`). Add `wokeAt` to `SleepSummary.init` with default nil (keeps callers compiling) and to `DailyMetrics` init default nil.
- [ ] **Step 4: Run** Core tests → PASS.
- [ ] **Step 5: Commit** `Core: wake-up time from the night's sleep`.

### Task 3: Schema, records and backfills

**Files:**
- Create: `Packages/Persistence/Sources/Persistence/Migrations/013_hydration.sql`
- Create: `Packages/Persistence/Sources/Persistence/CaffeineMlMigration.swift`
- Modify: `Packages/Persistence/Sources/Persistence/Migrator.swift` (register `013_hydration`, `014_caffeine_ml` coded)
- Modify: `Records.swift` (`Food.countsAsFluid: Bool?`, `DiaryEntry.fluidMl: Double?`, `Profile.waterGoalMode: HydrationGoalMode`), `CaffeineRepository.swift` (`CaffeineEntry.ml: Double?`), `DailyMetricsRepository.swift` (`DailyMetricsRecord.wokeAt: Date?`, copied from/to `DailyMetrics`)
- Test: `Packages/Persistence/Tests/PersistenceTests/HydrationMigrationTests.swift`

**Interfaces:**
- Consumes: `HydrationGoalMode` (Task 1), `CaffeineDrink.preset(id:)`, `DailyMetrics.wokeAt` (Task 2).
- Produces: the columns `diary_entry.fluid_ml REAL`, `food.counts_as_fluid INTEGER`, `caffeine_entry.ml REAL`, `daily_metrics.woke_at TEXT`, `profile.water_goal_mode TEXT NOT NULL DEFAULT 'weight' CHECK (...)` and their record properties.

- [ ] **Step 1: Failing tests** (migrate a DB to `012`, insert rows with raw SQL, then migrate to the end — follow the existing migration test helpers in `PersistenceTests`):
  - `backfillsDiaryFluidForLiquidFoods`: milk (liquid, fat 2.8) 250 → `fluid_ml == 250`; olive oil (liquid, fat 100) 15 → nil; oats (solid) → nil; quick-add → nil; entry whose food row is gone (`food_id` NULL) → nil.
  - `goalModeFixedOnlyForCustomGoal`: profile 2500 → `weight`; profile 3000 → `fixed`.
  - `backfillsCaffeineMlFromPreset`: `drink_id 'espresso'` → 30; `'cola'` → 330; NULL drink → nil; unknown id → nil.
  - `recordsRoundTripNewColumns`: save/fetch each record with the new properties set.
- [ ] **Step 2: Run** `cd Packages/Persistence && swift test --filter HydrationMigrationTests` → FAIL.
- [ ] **Step 3: Implement** `013_hydration.sql` (ALTERs + `UPDATE diary_entry SET fluid_ml = grams WHERE food_id IN (SELECT id FROM food WHERE is_liquid = 1 AND fat_g_100 <= 50) AND grams > 0` + `UPDATE profile SET water_goal_mode = 'fixed' WHERE water_goal_ml <> 2500`); `CaffeineMlMigration.run(db)` updates each `caffeine_entry` with a known `drink_id` from `CaffeineDrink.all`. Add a partial index `idx_diary_entry_fluid ON diary_entry(day) WHERE fluid_ml > 0 AND deleted_at IS NULL`. Add the record properties and coding keys.
- [ ] **Step 4: Run** the whole Persistence suite → PASS (existing migration/export tests must still pass).
- [ ] **Step 5: Commit** `Persistence: hydration schema (013, 014) and records`.

### Task 4: Write paths and the merged intake observation

**Files:**
- Modify: `DiaryRepository.swift` (`insertFoodEntry`, `updateQuantity`), `MealPlanRepository.swift` (mark eaten), `CaffeineRepository.swift` (`add(…, ml:)`), `DailyMetricsRepository.swift` (store `woke_at`; `weightTrendKg(onOrBefore:)`, `weightTrends(in:)`), `DataPortability.swift` (export/import new columns)
- Create: `Packages/Persistence/Sources/Persistence/HydrationRepository.swift`
- Test: `Packages/Persistence/Tests/PersistenceTests/HydrationRepositoryTests.swift`, additions in `DiaryRepositoryTests.swift`, `CaffeineRepositoryTests.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 3 columns.
- Produces:
  - `DiaryRepository.fluidMl(for food: Food, baseAmount: Double) -> Double?` (static, uses `FluidRule.counts(isLiquid:fatPer100:override:)` with `food.per100.fatG`)
  - `CaffeineRepository.add(mg:day:loggedAt:drinkID:name:ml: Double? = nil)` — when `ml` is nil and `drinkID` is a preset, store the preset's `servingMl`.
  - `DailyMetricsRepository.weightTrendKg(onOrBefore: LocalDay) throws -> Double?`, `weightTrends(in: ClosedRange<LocalDay>) throws -> [LocalDay: Double]` (each day → latest trend on or before it; days before any trend absent).
  - `public struct HydrationRepository { init(_ database: AppDatabase); func intakes(in days: ClosedRange<LocalDay>) throws -> [LocalDay: [FluidIntake]]; func observeIntakes(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[LocalDay: [FluidIntake]]> }` — water entries (`kind .water`, source `.water`, name "Water"), diary rows with `fluid_ml > 0` (kind `.other`, source `.diary`, name `display_name`), caffeine rows with `ml > 0` (kind `.other`, source `.caffeine`, name `name` or preset name); active rows only; each day sorted by `(at, id)`; `id` = the source row id.

- [ ] **Step 1: Failing tests:**
  - Diary: `logLiquidFoodSnapshotsFluid` (cola 330 → 330), `logOilHasNoFluid`, `overrideOnCountsSolidFood` (soup solid + `countsAsFluid = true`, 300 g → 300), `logAllAndMealPlanSnapshotFluid`, `updateQuantityScalesFluid` (330 → 500), `changingFoodOverrideKeepsOldEntries`.
  - Caffeine: `presetStoresServingMl`, `customAmountStoresGivenMl`, `customWithoutMlIsNil`.
  - Metrics: `wokeAtRoundTrips`, `weightTrendOnOrBefore`.
  - `HydrationRepositoryTests`: `mergesThreeSources` (one of each, sorted), `excludesDeletedAndNonFluid`, `observationEmitsOnDiaryChange`.
  - Export/import: `exportImportKeepsHydrationColumns` (extend existing round-trip test).
- [ ] **Step 2: Run** `cd Packages/Persistence && swift test` → new tests FAIL.
- [ ] **Step 3: Implement.** `insertFoodEntry` and meal plan set `entry.fluidMl = fluidMl(for: food, baseAmount:)` (meal plan: from the fetched food; nil when the food is gone or the plan is quick-add). `updateQuantity`: `entry.fluidMl = entry.fluidMl.map { $0 * newAmount / oldGrams }`.
- [ ] **Step 4: Run** `swift test` for Persistence → PASS.
- [ ] **Step 5: Commit** `Persistence: snapshot fluid volume, merged hydration intakes`.

### Task 5: Hydration settings, goal and the settings screen

**Files:**
- Create: `App/Sources/Dashboard/HydrationSettings.swift`, `App/Sources/Dashboard/HydrationSettingsView.swift`
- Delete: `App/Sources/Dashboard/WaterSettingsView.swift` (its quick-add editor moves into `HydrationSettingsView` as a section; keep `WaterQuickAdd` in `DashboardTiles.swift`)
- Modify: `App/Sources/AppEnvironment.swift` (`SettingKey` additions; `hydration: HydrationRepository?`), `App/Sources/Settings/SettingsView.swift` (water goal row → "Hydration" link), `App/Sources/Dashboard/TileDetailView.swift` (link target)
- Test: `Tests/VitalionTests/HydrationSettingsTests.swift`

**Interfaces:**
- Produces:
  - `SettingKey.hydrationFallbackWakeMinutes`, `.hydrationGapMinutes`, `.hydrationBehindMarginMl`, `.hydrationRemindersEnabled`.
  - `struct HydrationSettings: Equatable { fallbackWakeMinutes = 420; bedtimeMinutes = CaffeineDefaults.defaultBedtimeMinutes; gapMinutes = 180; behindMarginMl = 500.0; remindersEnabled = false; static let gapRange = 60...360, gapStep = 30, marginRange = 250.0...1000, marginStep = 50; static func load(from: ProfileRepository) -> HydrationSettings; func save(to: ProfileRepository) throws }` — bedtime reads/writes `SettingKey.caffeineBedtimeMinutes`; values normalized like `CaffeineSettings`.
  - `HydrationSettings.wake(on day: LocalDay, wokeAt: Date?, calendar:) -> Date` (wokeAt if on that day, else fallback) and `bedtime(on:calendar:) -> Date` (bedtime ≤ wake fallback → next day's clock time, so 01:00 bedtimes work).
  - `HydrationGoalResolver.goalMl(on day: LocalDay, profile: Profile, trendKg: Double?) -> Double` (wraps `HydrationGoal.ml`).
- [ ] **Step 1: Failing tests:** `defaultsWhenNothingStored`, `normalizesOutOfRangeValues` (gap 20 → 60, margin 1200 → 1000), `bedtimeSharedWithCaffeine` (save via Hydration, `CaffeineSettings.load` sees it), `wakeUsesHealthThenFallback`, `bedtimeAfterMidnight`.
- [ ] **Step 2: Run** `xcodebuild test … -only-testing:VitalionTests/HydrationSettingsTests` → FAIL.
- [ ] **Step 3: Implement** settings + view: sections Goal (Picker "Based on weight (30 ml/kg)" / "Fixed amount" bound to `profile.waterGoalMode`, computed value text "2 400 ml at 80.0 kg" or "Log your weight to personalise this goal", Stepper for fixed), Quick-add sizes (moved code), Your day (fallback wake `DatePicker`, footer "Uses the time you woke up from Apple Health sleep when available.", bedtime `DatePicker`), Reminders (Toggle — on enable call `environment.hydrationReminder.requestAuthorization()`, revert to off if denied and show "Notifications are off for Vitalion" with a link to `UIApplication.openNotificationSettingsURLString`; Steppers for gap "Remind after 3 h without a drink" and margin "Or when 500 ml behind pace"). Title "Hydration". Run `xcodegen generate`.
- [ ] **Step 4: Run** tests → PASS; build succeeds.
- [ ] **Step 5: Commit** `App: Hydration settings and weight-based goal`.

### Task 6: Dashboard data, Today tile and bubble strip

**Files:**
- Modify: `App/Sources/Dashboard/DashboardModel.swift` (observe `HydrationRepository` for the 7-day range instead of water-only; build `HydrationDay` for today; per-day goals for history), `DashboardSnapshot.swift` (water section → hydration: total, breakdown, status, strip data), `DashboardTiles.swift` (title "Hydration"; `WaterGoal` colours from `HydrationStatus`), `DashboardView.swift` / `WaterTileContent` (strip), `DashboardAccessibility.swift`, `Sparkline.swift` (7-day totals incl. drinks)
- Create: `App/Sources/Dashboard/HydrationStrip.swift`
- Test: `Tests/VitalionTests/HydrationTileTests.swift`

**Interfaces:**
- Consumes: `HydrationRepository.observeIntakes(in:)`, `HydrationSettings`, `HydrationGoalResolver`, `DailyMetricsRecord.wokeAt/waterMl/weightTrendKg`.
- Produces: `DashboardModel.hydrationDay(at: Date) -> HydrationDay` (today, used by tile, detail and reminder service); `DashboardData.hydrationIntakes: [LocalDay: [FluidIntake]]`; `HydrationStrip(day: HydrationDay)` view.

- [ ] **Step 1: Failing tests:** `tileShowsTotalAndBreakdown` ("1 840 / 2 400 ml", "1 300 water · 540 drinks"), `tileStatusBehindColorsOrange`, `goalUsesTrendWeight`, `otherAppsWaterInTotalNotStrip`, `dayRolloverSwitchesToNewDay` (injected clock 23:59 → 00:01, intakes empty, total 0).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Strip: `Canvas` or `HStack`-free `GeometryReader` drawing wake→bedtime axis, circles with radius `sqrt(ml) * k` (k so 500 ml ≈ 11 pt), water `NL` water colour / other drinks the secondary chart colour, gap rects with destructive tint 0.12, now tick; accessibility label "8 drinks, longest gap 4 h 30 min". Use the design-system tokens already used by `CaffeineTile`.
- [ ] **Step 4: Run** tests → PASS.
- [ ] **Step 5: Commit** `Today: Hydration tile with drink strip`.

### Task 7: Hydration detail screen

**Files:**
- Create: `App/Sources/Dashboard/HydrationDetailView.swift`, `App/Sources/Dashboard/HydrationChart.swift`, `App/Sources/Dashboard/HydrationEntrySheet.swift`
- Modify: `TileDetailView.swift` (route `.water` to `HydrationDetailView`, remove the old water branch), `DashboardModel.swift` (`addWater(ml:loggedAt:)`; `deleteIntake(_ intake: FluidIntake)` for `.water`/`.caffeine` with undo), `DashboardModel.history(for:)` (hydration totals vs. per-day goals)
- Test: `Tests/VitalionTests/HydrationDetailTests.swift`

**Interfaces:**
- Consumes: `DashboardModel.hydrationDay(at:)`, `HydrationDay`, `HydrationStatus`.
- Produces: `HydrationStatusText.line(_ status: HydrationStatus, now: Date) -> String` ("Goal reached", "On pace", "500 ml behind pace", "No drink for 3 h 20 min").

- [ ] **Step 1: Failing tests:** `statusLines` (four cases above), `deleteWaterIntakeOffersUndo`, `deleteCaffeineIntakeOffersUndo`, `diaryIntakeNotDeletable`, `addWaterAtEarlierTime`, `historyUsesPerDayGoal`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** per spec §3 detail: `TimelineView(.periodic(by: 60))`; chart = `LineMark` step (`.interpolationMethod(.stepEnd)`) of `steps`, dashed `LineMark` pace wake→paceEnd, `RuleMark` goal, `PointMark` per intake coloured by kind, `RectangleMark` per gap, `RuleMark` now; sections Breakdown (footer "Water from other apps comes from Apple Health without times, so it isn't on the chart."), Add water (Menu of sizes + "Other amount or time…" → `HydrationEntrySheet` with ml stepper and time picker), Today's drinks (swipe delete for water/caffeine; diary rows show meal name, no swipe), Last 14 days, link "Hydration settings", "How this works" text.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `Today: Hydration detail with pace chart and gaps`.

### Task 8: Food "Counts as a drink" and caffeine volume

**Files:**
- Modify: `App/Sources/Foods/FoodEditorModel.swift`, `FoodEditorView.swift`, `App/Sources/Dashboard/CaffeineDetailView.swift` (`CaffeineEntrySheet`), `DashboardModel.addCaffeine(...)` (pass `ml`)
- Test: `Tests/VitalionTests/FoodEditorModelTests.swift` (add), `CaffeineTileTests.swift` (add)

**Interfaces:**
- Consumes: `Food.countsAsFluid`, `FluidRule.counts`, `CaffeineRepository.add(…ml:)`.

- [ ] **Step 1: Failing tests:** `countsAsDrinkAutomaticDescribesRule` (liquid milk → "Automatic (counts)", oil → "Automatic (doesn't count)"), `savingOverridePersists`, `customCaffeineWithMlStoresMl`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** Picker "Counts as a drink": Automatic / On / Off, footer "Applies to new diary entries." Caffeine sheet: optional "Volume (ml)" `TextField` (number pad), empty → nil.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `Foods: "Counts as a drink"; caffeine volume`.

### Task 9: Reminders

**Files:**
- Create: `App/Sources/Dashboard/HydrationReminder.swift` (protocol + `LocalNotificationHydrationReminder` + `NoHydrationReminder`), `App/Sources/Dashboard/HydrationReminderService.swift`, `App/Sources/Shared/NotificationDelegate.swift`
- Modify: `AppEnvironment.swift` (`hydrationReminder`, `hydrationReminderService`; start at launch; recompute on foreground and after Health sync/import/restore), `VitalionApp.swift` (set `UNUserNotificationCenter.current().delegate`, register category), `RootView.swift` (deep link to Hydration detail)
- Test: `Tests/VitalionTests/HydrationReminderServiceTests.swift`

**Interfaces:**
- Consumes: `HydrationReminder.next(day:tomorrowWake:)`, `DashboardModel`-independent inputs: `HydrationRepository`, `DailyMetricsRepository`, `ProfileRepository`, `WaterRepository`, `AppClock`.
- Produces:
  - `protocol HydrationReminderScheduling: Sendable { func requestAuthorization() async -> Bool; func isAuthorized() async -> Bool; func schedule(at: Date, title: String, body: String, actionTitle: String) async throws; func cancel() async }`
  - `@MainActor final class HydrationReminderService { init(environment deps…, scheduler:, clock:); func recompute() async; func handleAddAction() async }`

- [ ] **Step 1: Failing tests** with a recording fake scheduler and fixed clock: `disabledCancels`, `unauthorizedCancelsWithoutThrow`, `schedulesGapReminderWithCopy` (exact title/body from Global Constraints), `schedulesBehindReminder`, `goalReachedCancels`, `addingDrinkReschedules`, `addActionLogsSmallestSizeAndReschedules`, `midnightRecomputesForNewDay`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Service observes `HydrationRepository.observeIntakes(today…today)` and settings/profile changes (follow how `AppEnvironment` reconciles the check-in reminder); it builds the `HydrationDay` the same way as `DashboardModel.hydrationDay` — extract that construction into one shared function `HydrationDayBuilder.make(…)` used by both. Delegate: `.HYDRATION_ADD` → `handleAddAction()`; default tap on `hydration-reminder` → post the deep link; other ids → leave to existing behaviour; `willPresent` returns `[.banner, .sound]`. Category action option `[]` (background).
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: Commit** `Hydration reminders (gap or behind pace) with +250 ml action`.

### Task 10: Widget, Siri and Trends

**Files:**
- Modify: `App/Sources/Shared/WidgetSnapshotWriter.swift`, `Widgets/` water views, `App/Sources/Intents/IntentActions.swift`, `VitalionIntents.swift` (dialog text), `App/Sources/Trends/*` (`ChartData`, `MetricChartView`, `StatsLoader`, `WeeklyReportView`) — label "Hydration", totals include drinks (`HydrationRepository.intakes(in:)` + other-app water), goal from `HydrationGoalResolver`.
- Test: existing intent/trends tests updated; add `IntentActionsTests.logWaterReportsHydrationTotal`.

- [ ] **Step 1: Failing test** `logWaterReportsHydrationTotal` (water 500 + diary cola 330, log 250 → dialog total 1 080).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** label/total changes; the "Log water" intent still logs plain water.
- [ ] **Step 4: Run** the whole app suite → PASS.
- [ ] **Step 5: Commit** `Widget, Siri, Trends: Hydration totals`.

### Task 11: Full verification

- [ ] Run every package: `for p in Core Persistence FoodSources FoodLookup HealthKitClient Scanner DesignSystem; do (cd Packages/$p && swift test) || echo FAIL $p; done` → no FAIL.
- [ ] Run the app suite (`xcodebuild test … -quiet`) → all pass.
- [ ] Simulator: seed a day (demo data), open Today → strip shows drinks and a gap; open detail → chart, pace, gaps; turn reminders on, set gap to 1 h, background the app, confirm the notification and the "+ 250 ml" action.
- [ ] Commit any fixes.
