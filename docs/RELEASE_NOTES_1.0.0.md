# Nutrilog 1.0.0 — release notes (draft)

v1.0.0 completes phase 3 of the [roadmap](SPEC.md#13-roadmap) and with it the v1 scope (phases 1–3).
This file is a draft until the tag is pushed: the success criteria at the end are the owner's to fill in.

## New since 0.2

**Recipes and saved meals**
- Recipes: ingredients with amounts, cooked weight or number of servings, nutrition per 100 g and per serving. Log by
  grams or by serving. "Scale all amounts" for a bigger or smaller batch, duplicate a recipe. Each ingredient keeps
  the values it had when it was added, and editing a recipe never changes what was already logged.
- Saved meals: "Save as meal…" in any meal's menu, then log it from Add food → Meals — every item with its amount,
  editable before confirming. Meals are ordered by how often and how recently you use them; an item whose food was
  deleted is flagged and can still be logged.

**Adaptive maintenance estimate and weekly check-in**
- Weight trend: a smoothed average of your weigh-ins (each moves it by 10 %); single jumps of more than 2.5 % count
  less. Shown on the weight tile, in the charts and in the weekly report — one trend everywhere.
- Estimated maintenance (TDEE) from the last 14 days: average logged intake minus the energy your weight trend says
  you stored or lost. Needs 7 logged days and 2 weigh-ins; shows low / medium / high confidence.
- Weekly check-in (Trends, and by itself on your check-in day): weekly trend change against your goal, the estimate,
  and a proposed calorie target you can accept, change or skip. Every number opens an explanation, and "How was this
  computed?" lists the days used. Past check-ins are kept in the history. Optional reminder notification.
- "Day fully logged" toggle in the diary. Days with fewer than 3 entries are left out of the estimate unless marked.
  A day or a fortnight that looks under-logged gets a gentle hint — the app never lowers your target because of it.

**History and analytics**
- History calendar: two years of months, each day colored by how close it was to the target that applied that day;
  tap a day to open it in the diary.
- Charts with 1W / 1M / 3M / 1Y, scrubbing and an average line: weight with trend, body fat, calories vs target,
  macros, steps, sleep, resting heart rate, HRV, water, active and total energy. Every dashboard tile opens its chart.
  Charts have a spoken summary for VoiceOver.
- Weekly report for any week: averages, closest and furthest day, intake against estimated expenditure, trend change;
  share it as an image rendered on the device.

**Siri, Shortcuts and widgets**
- Shortcuts actions that run without opening the app: Log Favorite Food, Quick-Add Calories, Remaining Calories,
  Log Water. They use the same storage as the app, so entries also reach Apple Health.
- Widgets: calories left (small, Lock Screen circular and inline), calories & macros (medium), today's metrics
  (medium, Lock Screen rectangular).

**Your data**
- Duplicate foods (Settings): foods sharing a barcode or the same name and brand can be merged; diary entries,
  recipes and saved meals move to the food you keep.
- Automatic weekly backup on the device (newest 7 kept), with restore and share in Settings → Backups.

## Changed
- The weight tile's trend is now the slower trend described above (it used to be a 7-day average), so it matches the
  charts and the estimate. Expect it to react less to single weigh-ins.
- A fifth tab, Trends.
- Database schema 7 (`007_tdee_estimate_details`). Exports from 1.0.0 can't be imported into older versions.

## Before tagging `v1.0.0`
- [ ] Run the app from Xcode on an iPhone once: confirms signing with the new widget extension and App Group
      (see [RELEASING.md](RELEASING.md) §1b).
- [ ] On the device, check what the simulator tests can't: add each widget, run the four Shortcuts actions (also by
      voice), turn on the check-in reminder.
- [ ] Fill in the success criteria below.

## v1 success criteria (SPEC §1.3) — to be recorded by the owner

| Criterion | Result |
|---|---|
| 30 consecutive days of real daily use without reverting to another app | _not yet recorded_ |
| ≥ 90 % of scanned barcodes of regularly purchased products resolve (Settings → Barcode resolution) | _not yet recorded_ |
| Dashboard shows intake, weight trend, steps and sleep for today with no manual input besides food | _not yet recorded_ |
| TDEE estimate shown with ≥ 14 days of data (Trends) | _not yet recorded_ |
