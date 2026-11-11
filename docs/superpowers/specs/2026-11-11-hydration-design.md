# Hydration (replaces the Water tile) — design

Date: 2026-11-11 · Branch: `memphin/fluid`

## Goal

Count every drink toward one daily fluid total, not only plain water, and show *when* during the day the user drank
and where the gaps are, with reminders when they go too long without a drink or fall behind pace. The Water tile is
renamed **Hydration**.

### Decisions (agreed in brainstorming)

| Topic | Decision |
|---|---|
| Name | "Hydration" (tile, detail, settings, widget, Trends) |
| What counts | Every drink at full volume (1:1): plain water, liquid diary entries, caffeine quick-adds. No hydration factors, no alcohol exclusion. |
| Apple Health | Only plain water is written to Health as `dietaryWater` (unchanged). Other drinks count only inside Vitalion. |
| Visuals | Detail: running total vs. pace line (option A). Today tile: bubble strip of drinks (option B). |
| Waking window | Wake-up time from Apple Health sleep, fallback setting (07:00). Bedtime shared with Caffeine (23:00). |
| Reminders | Yes, in this release: earlier of "gap" and "behind pace", one pending notification, "+ 250 ml" action. |
| Which foods count | Automatic (liquid and fat ≤ 50 g/100 ml), with a per-food "Counts as a drink" override. |
| Storage | Snapshot each drink's volume at log time (approach 1). |
| Goal | 30 ml × current trend weight, rounded to 50 ml; fixed amount as an override. |

## 1. Data (migration `013_hydration.sql`, plus Swift-coded backfill where SQL is not enough)

- `diary_entry.fluid_ml REAL` — NULL = not a drink. Set at log time when `FluidRule.counts(food:)` is true:
  `fluid_ml = grams` (for a liquid food `grams` is ml; for a food forced on with a solid base unit, grams are taken as
  ml). Quick-add diary entries (no food) have NULL. Editing an entry's amount scales `fluid_ml` proportionally.
- Backfill: existing active and deleted entries whose food has `is_liquid = 1` and `fat_g_100 <= 50` get
  `fluid_ml = grams`, also when the food was soft-deleted later (a logged drink stays a drink, like its saved
  nutrients). Entries whose food row is gone (`food_id` NULL) stay NULL. Importing an export from before this
  change re-runs these backfills, like the importer re-runs earlier data repairs.
- `food.counts_as_fluid INTEGER` — NULL automatic, 1 always, 0 never.
- `caffeine_entry.ml REAL` — preset `servingMl` at log time; optional for custom amounts. Backfill from `drink_id`
  via the preset table (Swift-coded, since presets live in Core).
- `daily_metrics.woke_at TEXT` — end of the last *asleep* sample ending before 12:00 local time of the chosen source
  for that night; NULL when none. Written by the sleep import.
- `profile.water_goal_mode TEXT NOT NULL DEFAULT 'weight' CHECK (water_goal_mode IN ('weight','fixed'))`.
  Migration sets `'fixed'` where `water_goal_ml != 2500`. `water_goal_ml` stays the fixed amount.
- Settings (one key each in the profile settings store, like the caffeine settings — `SettingKey`):
  `hydrationFallbackWakeMinutes` (420), `hydrationGapMinutes` (180, range 60–360, step 30),
  `hydrationBehindMarginMl` (500, range 250–1000, step 50), `hydrationRemindersEnabled` (false).
- Bedtime: the existing `caffeineBedtimeMinutes` key becomes the app's one bedtime (no data move); it is edited in
  both Caffeine and Hydration settings.
- Goal weight: the latest `daily_metrics.weight_trend_kg` on or before the day; for a day with none (e.g. weight
  logged only in Vitalion, without Apple Health), the weight trend computed from the weigh-ins
  (`StatsLoader.dayWeights` + `WeightTrend.trendByDay`, as the weight screens do). No `daily_metrics` rows are
  created for it. One lookup (`HydrationGoalResolver.trendsKg`) serves every surface.
- Export/import include the new columns and settings.

## 2. Core logic (`Packages/Core/Sources/Core/Hydration.swift`, pure)

- `FluidIntake { id, ml, at: Date, kind: .water | .other, source: .water | .diary | .caffeine, name }`.
- `FluidRule.counts(isLiquid:, fatPer100:, override:) -> Bool`; `FluidRule.maxFatPer100 = 50`.
- `HydrationGoal.ml(weightKg: Double?, mode:, fixedMl:) -> Double` — weight mode: `round(30 × kg / 50) × 50`;
  no weight → 2500. `mlPerKg = 30`, `fallbackMl = 2500`.
- `HydrationDay(intakes:, otherAppsMl:, goalMl:, wake:, bedtime:, gapThreshold:, behindMarginMl:, now:)` gives:
  - `totalMl`, `waterMl`, `otherDrinksMl`, `otherAppsMl`;
  - `steps` — running total of timed intakes, in time order;
  - `pace(at:)` — 0 at wake, linear to `goalMl` at `bedtime − 1 h`, flat after; `paceEnd`;
  - `gaps` — intervals > threshold inside [wake, min(now, bedtime)] with no timed intake: wake→first, between,
    last→now (`isOngoing`). Other-apps water does not close gaps. Intakes outside the window count in totals only;
  - `status` — `.goalReached`, `.inGap`, `.behind`, `.onPace` (in that precedence);
  - If `wake >= bedtime − 1 h` the window is invalid: no gaps, no pace (`pace` returns nil), status `.onPace` unless
    goal reached.
- `HydrationReminder.next(day: HydrationDay, tomorrowFallbackWake: Date, ...) -> HydrationReminder.Plan?`
  (`date`, `reason: .gap(since: Date) | .behind(expectedMl:)`):
  - nil if goal reached;
  - gap time = max(last timed intake, wake) + threshold; behind time = first t ≥ now with
    `pace(t) − totalMl ≥ margin` (solved analytically);
  - earliest of those that is ≥ now and ≤ bedtime − 1 h; otherwise tomorrow at `tomorrowFallbackWake + threshold`
    with reason `.gap(since: tomorrowFallbackWake)`.

## 3. Screens

- **Today tile** (`DashboardTile.water`, title "Hydration", icon `drop`): "1 840 / 2 400 ml", subline
  "1 300 water · 540 drinks", bubble strip wake→bedtime (bubble area ∝ ml, water `chart-1`, other `chart-2`, now
  tick, gaps tinted), existing quick-add buttons (plain water). Colour from status.
- **Detail** (`HydrationDetailView`, replaces the water branch of `TileDetailView`): header total + status line;
  Swift Charts running total (step line) + dashed pace + goal rule + intake points + gap rectangles + now rule;
  breakdown (water / other drinks / other apps, note that other-app water has no times); add water (sizes + "Other
  amount or time…"); today's drinks (water and caffeine quick-adds deletable with undo, diary rows read-only with
  meal name); last 14 days vs. that day's goal; link to settings; "How this works".
- **Settings → Hydration** (`HydrationSettingsView`, absorbs `WaterSettingsView`): goal mode + computed value;
  quick-add sizes; wake-up (fallback time, note about Health), bedtime (shared); reminders toggle (requests
  permission), gap threshold, behind margin; denied-permission note.
- **Food editor**: "Counts as a drink" picker Automatic (shows current meaning) / On / Off; note: applies to new
  entries.
- **Caffeine custom sheet**: optional "Volume (ml)".
- **Home Screen widget, Siri, Trends**: label "Hydration", full total, computed goal. "Log water" intent still logs
  plain water.

## 4. Reminders

- `HydrationReminderScheduling` protocol (`requestAuthorization`, `isAuthorized`, `schedule(plan:content:)`,
  `cancel`) with `LocalNotificationHydrationReminder` and `NoHydrationReminder`. Fixed identifier
  `hydration-reminder`; category `HYDRATION` with action `HYDRATION_ADD` ("+ 250 ml", smallest quick-add size,
  background action).
- `HydrationReminderService` (owned by `AppEnvironment`): recomputes on drink changes (water, diary, caffeine
  observations), Health sync, settings/goal changes, launch, foreground, day change. Cancels when disabled or not
  authorised.
- Notification delegate (new `NotificationDelegate`, set at launch): `HYDRATION_ADD` → add water, recompute;
  default tap on a hydration notification → open the Hydration detail. Check-in notifications unaffected.
- Copy: gap — "Time for a drink" / "No drink since 13:00 · 1 320 of 2 400 ml"; behind — "You're behind on
  hydration" / "1 100 ml so far — about 1 600 by now keeps you on track".
- Limitation: drinks logged in other apps reach Vitalion only via Health background delivery or next foreground.

## 5. Edge cases and testing

Edge cases as listed in §2 (invalid window, intakes outside window, no weight, no wake). Day membership by the
entry's `day`. Device time zone.

Tests (Swift Testing, TDD):
- Core `HydrationTests`: totals/breakdown; pace start/mid/end/invalid; gaps none/between/ongoing/night/threshold;
  status precedence; reminder gap-wins/behind-wins/goal-reached/too-late/tomorrow; `FluidRule`; `HydrationGoal`.
- Persistence: migration 013 backfills and goal-mode carry-over; diary `fluid_ml` at log and on edit;
  caffeine `ml`; sleep import `woke_at` ignoring afternoon naps.
- App: tile snapshot numbers/status; reminder service with fake scheduler; notification action logs water.
- Manual: simulator full-day strip and chart; reminder firing and action.

## Out of scope

Hydration factors, alcohol detection, writing non-water drinks to Health, timestamps for other-app water, more than
one pending reminder.
