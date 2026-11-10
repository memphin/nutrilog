# Backlog — Phases 1–3

Generated from `backlog/issues.json`. Import into GitHub with `tools/import_issues.sh` (requires `gh`). Each issue references SPEC requirement IDs.


## Phase 1 — MVP diary


### 1. Core: nutrient math and quantity model
`labels: core, phase-1`

Pure-Swift `Nutrients` value type (kcal, protein, carbs, fat, fiber?, sugar?, satFat?, sodium?) with scaling from per-100 g to any gram/ml amount, addition, and rounding rules for display.

**Acceptance criteria**
- [ ] `Nutrients.scaled(toGrams:)` and `+` are covered by unit tests incl. optional fields (nil + value = value)
- [ ] Serving → grams conversion handles `is_liquid` (ml)
- [ ] kcal is never recomputed from macros; stored value wins
- [ ] 100% test coverage on this type

Refs: SPEC §5.1 FR-2, §8


### 2. Persistence: Food, Serving, FoodBarcode records and repository
`labels: persistence, phase-1`

GRDB `Record` types for `food`, `serving`, `food_barcode` plus a `FoodRepository` (create/update/soft-delete, fetch by id, by barcode, favorites, recents).

**Acceptance criteria**
- [ ] Soft delete sets `deleted_at`, bumps `revision`, excluded from default fetches
- [ ] `updated_at` auto-set on save
- [ ] Barcode normalization (UPC-A → EAN-13, checksum validation) lives in Core and is tested
- [ ] Repository tests on in-memory DB

Refs: SPEC §8, ADR-0003


### 3. Persistence: DiaryEntry, MealSlot, DayNote records and repository
`labels: persistence, phase-1`

Records + `DiaryRepository`: entries for a day grouped by slot, insert with nutrient snapshot, move between slots/days, reorder, soft delete; day totals query.

**Acceptance criteria**
- [ ] Snapshot columns are filled from the food at insert time and never recalculated on later food edits
- [ ] `ValueObservation` publisher for a day's entries + totals
- [ ] Tests: totals across slots, move entry, quick-add without food_id

Refs: FR-1, FR-2, FR-3, FR-5, FR-6, FR-7


### 4. Persistence: FTS5 food search service
`labels: persistence, phase-1`

`FoodSearch.search(query:limit:)` over `food_fts` with prefix matching, diacritic insensitivity, ranking by `bm25` then `use_count`/`last_used_at`.

**Acceptance criteria**
- [ ] "cokolada" matches "Čokolada"; "chick br" matches "Chicken breast"
- [ ] Results < 100 ms for 10k rows (measure in test with generated data)
- [ ] Deleted foods excluded

Refs: FR-20, FR-21, NFR-3, ADR-0002


### 5. Persistence: bundled USDA food index loader
`labels: persistence, phase-1`

Open `Resources/FoodIndex/bundled_foods.sqlite` read-only via GRDB, search it alongside user foods, and copy a bundled row into `food` (source='bundled') the first time it is logged.

**Acceptance criteria**
- [ ] Unified search merges user + bundled results with source badges
- [ ] Copy-on-first-use keeps `source_id` = fdc_id so duplicates are avoided
- [ ] `tools/build_food_index.py` output committed with ≥ 300 foods

Refs: §3.2, FR-20


### 6. UI: DesignSystem package (tokens, typography, components)
`labels: ui, phase-1`

Colors (semantic + macro colors: protein/carbs/fat), typography scale, spacing, `MacroRing`, `MacroBar`, `NutrientRow`, `SourceBadge`, empty-state and error views. Liquid Glass-compatible, Dynamic Type, dark mode.

**Acceptance criteria**
- [ ] SwiftUI previews for every component in light/dark and XXL text size
- [ ] VoiceOver labels on rings/bars read values (e.g. "Protein 120 of 160 grams")

Refs: FR-73, NFR-7


### 7. UI: Diary screen (day view with meal slots)
`labels: ui, phase-1`

Date navigation (swipe/arrows/today), meal sections with entries, per-section subtotals, day summary header (kcal remaining ring + macro bars), swipe-to-delete, context menu (edit, move, duplicate).

**Acceptance criteria**
- [ ] Live updates via observation; no manual refresh
- [ ] Deleting is undoable for 5 s (snackbar)
- [ ] Works offline

Refs: FR-1, FR-3, FR-6


### 8. UI: Add food flow (search, recents, favorites, quantity picker)
`labels: ui, phase-1`

Tapping "+" on a slot opens search with segmented tabs: Recents / Favorites / All. Selecting a food opens quantity sheet (grams or servings, live nutrient preview), then logs.

**Acceptance criteria**
- [ ] Logging a recent food takes ≤ 3 taps
- [ ] Quantity sheet remembers last-used serving per food
- [ ] Recents ordered by slot-aware frequency (breakfast foods first in the morning)

Refs: FR-22, §1.1 goal 1


### 9. UI: Create / edit custom food
`labels: ui, phase-1`

Form: name, local name, brand, barcode(s), per-100 g nutrients (kcal, P, C, F required), optional fiber/sugar/sat fat/sodium (salt input auto-converts to sodium), servings list, liquid toggle.

**Acceptance criteria**
- [ ] Validation: kcal plausibility check vs. 4/4/9 macro calc (warn if > 15% off, don't block)
- [ ] Salt ↔ sodium conversion (salt g × 400 = sodium mg)
- [ ] Per-serving entry mode: user types nutrients per serving + serving grams → stored per 100 g

Refs: FR-23, §9 mapping notes


### 10. UI: Quick-add calories/macros
`labels: ui, phase-1`

Entry without a food: kcal required, macros optional, optional name. Stored as `is_quick_add = 1`.

**Acceptance criteria**
- [ ] Appears in diary with a distinct icon
- [ ] Editable like any entry

Refs: FR-5


### 11. Profile & targets: Mifflin-St Jeor, activity factor, goal rate, macro split
`labels: core, ui, phase-1`

Profile form (height, birth date, sex, activity) and Targets screen: computed kcal with manual override, macros as grams or %, validation that % sum to 100, goal mode and rate shows implied deficit/surplus. Targets saved as a new versioned `target` row.

**Acceptance criteria**
- [ ] Core: `BMR.mifflinStJeor` and `TDEE.baseline` unit-tested against published examples
- [ ] Changing targets today does not alter past days' adherence
- [ ] Weight input falls back to manual until HealthKit (phase 2) exists

Refs: FR-30–33


### 12. Copy meal / copy day
`labels: ui, phase-1`

From any meal section: "Copy from yesterday" and "Copy from date…"; from day menu: "Copy whole day". Entries are duplicated with fresh ids and today's snapshot.

**Acceptance criteria**
- [ ] Copy preserves grams/servings; snapshot recomputed from current food values (documented behavior)
- [ ] Undo supported

Refs: FR-4


### 13. Export JSON (full) and CSV (diary, weights)
`labels: core, persistence, phase-1`

Settings → Export: versioned JSON (`schemaVersion`, all tables incl. tombstones) and CSV files; share sheet.

**Acceptance criteria**
- [ ] JSON round-trips through Import (#import issue) with byte-identical data
- [ ] CSV opens in Numbers/Excel with correct decimals
- [ ] Export of 5k entries < 2 s

Refs: FR-60


### 14. Import / restore from own JSON export
`labels: core, persistence, phase-1`

Restore into empty DB or merge (by id, newer `updated_at` wins).

**Acceptance criteria**
- [ ] Schema version check with clear error for newer files
- [ ] Merge test: conflicting rows resolved LWW

Refs: FR-61, ADR-0003


### 15. Settings: meal slots, units, data sources, export, about/licenses
`labels: ui, phase-1`

Editable meal slots (rename, reorder, add, deactivate), kJ display toggle, water goal, list of network destinations (NFR-1), OFF/USDA attributions, open-source licenses.

**Acceptance criteria**
- [ ] Attribution text for Open Food Facts exactly as required by ODbL
- [ ] "Network" section lists every host the app contacts

Refs: NFR-1, NFR-6, §3.1


### 16. Phase 1 exit: 7-day dogfooding + CI coverage gate
`labels: ci, phase-1`

Owner logs 7 consecutive days. Add coverage report to CI and fail if Core < 70%.

**Acceptance criteria**
- [ ] 7 days of real entries in the owner's DB
- [ ] Coverage gate active

Refs: §13 Phase 1 exit


## Phase 2 — Barcode, online sources, Health


### 17. Scanner package: VisionKit DataScannerViewController wrapper
`labels: scanner, phase-2`

SwiftUI wrapper with continuous scanning of EAN-13/EAN-8/UPC-A/UPC-E/Code-128, torch toggle, haptic on detection, debounce (same code within 2 s ignored), camera permission handling, manual barcode entry fallback.

**Acceptance criteria**
- [ ] Scan-to-callback < 300 ms in good light
- [ ] Permission denied → explanatory view with link to Settings
- [ ] Manual entry validates checksum

Refs: FR-10, FR-14


### 18. FoodSources: Open Food Facts v2 client + nutrient mapper
`labels: food-sources, phase-2`

`OpenFoodFactsClient.product(barcode:)` with fields allowlist and User-Agent; mapper to `Food` handling kcal vs kJ, salt→sodium, serving_quantity parsing, per-serving-only products, `data_quality` classification; `status 0` → notFound.

**Acceptance criteria**
- [ ] Fixture-based tests for ≥ 10 real OFF payloads (incl. kJ-only, per-serving-only, missing macros, Croatian product)
- [ ] Timeout 8 s, 2 retries with backoff, offline → `.offline` error
- [ ] Never crashes on malformed numbers (strings vs numbers in OFF JSON)

Refs: §3.1, §9


### 19. Barcode lookup pipeline + OFF product cache
`labels: food-sources, persistence, phase-2`

`BarcodeLookup.resolve(code)`: local `food_barcode` → `off_product_cache` (< 30 d) → network → cache. Returns `.local(Food)`, `.remote(Food, quality)`, `.notFound`.

**Acceptance criteria**
- [ ] Pipeline tests with stubbed client for each branch
- [ ] Cache eviction job for entries > 90 d

Refs: §9, FR-11


### 20. UI: Scan flow — product card, quantity, log; not-found → create food
`labels: ui, phase-2`

After scan: product card (image, name, brand, Nutri-Score, per-100 g & per-serving table, data-quality warning), quantity sheet, log. Not found: Create Food form prefilled with barcode; option to photograph the label for reference (stored locally only).

**Acceptance criteria**
- [ ] Partial-data products show "Complete nutrition" CTA that opens the edit form prefilled
- [ ] Created foods are found on the next scan without network
- [ ] Continuous mode: log and keep scanning (shopping-list style)

Refs: FR-12, FR-13


### 21. FoodSources: USDA FoodData Central search (optional key)
`labels: food-sources, phase-2`

`USDAClient.search(query:)` using key from Keychain (Settings) or build config. Map Foundation/SR Legacy/Branded results to `Food` (source='usda'). Rate-limit aware (429 → disable for 1 h with UI notice).

**Acceptance criteria**
- [ ] Without a key the source is hidden, app fully functional
- [ ] Key stored in Keychain; never logged
- [ ] Fixture tests for nutrient id mapping

Refs: §3.2, ADR-0004


### 22. Online search tab (OFF full-text + USDA) with source badges
`labels: food-sources, ui, phase-2`

"Online" segment in Add Food: parallel queries to OFF v1 search (packaged) and USDA (generic), merged list with badges, debounced input, cancellation.

**Acceptance criteria**
- [ ] Typing stops → results within 1.5 s on Wi-Fi
- [ ] Selecting an online result stores a local `food` copy (source off/usda) before logging

Refs: FR-20


### 23. HealthKitClient: authorization and type catalog
`labels: healthkit, phase-2`

Request read types (steps, bodyMass, bodyFatPercentage, activeEnergyBurned, basalEnergyBurned, sleepAnalysis, restingHeartRate, heartRateVariabilitySDNN, dietaryWater, height, dateOfBirth, biologicalSex) and write types (dietary* + bodyMass + dietaryWater). Info.plist strings, capability, Background Delivery.

**Acceptance criteria**
- [ ] Onboarding explains each type before the system prompt
- [ ] Read-denied is presented as "no data — check Health permissions" (opaque status)
- [ ] Protocol-based client so UI/tests use a fake

Refs: §3.4, FR-40


### 24. HealthKit: daily metrics fetch (steps, energy, weight, body fat, HR, HRV, water)
`labels: healthkit, core, phase-2`

Statistics collection queries per day: steps/active/basal (cumulativeSum, de-duplicated), earliest bodyMass + bodyFat of day, restingHeartRate (discrete), HRV SDNN overnight average (00:00–09:00), dietaryWater sum. Writes `daily_metrics`.

**Acceptance criteria**
- [ ] Day boundaries in user's local calendar incl. DST days (tests with fixed TimeZone)
- [ ] Backfill last 90 days on first authorization
- [ ] Source summary JSON records which device provided each metric

Refs: FR-41, FR-47, FR-48, D5


### 25. HealthKit: sleep aggregation (Apple Watch only, stages)
`labels: healthkit, core, phase-2`

Night window 18:00 D-1 → 18:00 D; sum asleep* samples from the highest-priority source (Watch); stage breakdown core/deep/REM/awake; in-bed vs asleep.

**Acceptance criteria**
- [ ] Core function `SleepAggregator.aggregate(samples:for:)` tested with overlapping samples, naps, iPhone-only nights (ignored when Watch present)
- [ ] Multi-source double counting impossible

Refs: §3.4 sleep rules, FR-41


### 26. HealthKit: background observers + refresh
`labels: healthkit, phase-2`

`HKObserverQuery` + `enableBackgroundDelivery(.hourly)` for each read type; on change recompute affected days; pull-to-refresh on dashboard.

**Acceptance criteria**
- [ ] Morning weigh-in appears on dashboard within 1 h without opening Health
- [ ] Observer completion handlers always called (no background budget leak)

Refs: FR-44


### 27. HealthKit: write dietary nutrients and water; keep in sync on edit/delete
`labels: healthkit, persistence, phase-2`

On entry save: write `dietaryEnergyConsumed`, protein, carbs, fat, fiber, sugar, sodium samples with metadata `HKMetadataKeyExternalUUID = entry.id`; store `healthkit_link` rows; edit → delete + rewrite; delete → delete samples. Same for water. Global toggle.

**Acceptance criteria**
- [ ] Never writes samples derived from Health reads (loop prevention)
- [ ] Toggle off → stops writing; existing samples untouched
- [ ] Orphan cleanup job: links whose entry is deleted → delete samples

Refs: FR-43, FR-46, §3.4 write loops


### 28. UI: Dashboard (today) with tiles
`labels: ui, phase-2`

Tiles: kcal remaining + macros, steps, sleep (h:min + stages), weight (latest, 7-day EMA, Δ7d), body fat %, active energy, resting HR, HRV (deviation vs 30-day avg), water (with quick-add). Reorderable/hideable.

**Acceptance criteria**
- [ ] All tiles populated with zero manual input after permissions (exit criterion §1.3)
- [ ] Tile tap → detail/chart screen (phase 3 may be a placeholder)
- [ ] Loading/empty/denied states per tile

Refs: FR-41, FR-45–48


### 29. Manual weight entry and water quick-add
`labels: ui, healthkit, phase-2`

Weight sheet (kg, optional body fat %) writes to Health unless disabled; water quick-add buttons (configurable sizes) and daily goal progress.

**Acceptance criteria**
- [ ] Manual weight shows immediately and reconciles with Health-sourced value for the day
- [ ] Water written as `dietaryWater`; other apps' water included in total

Refs: FR-42, FR-46


### 30. Phase 2 exit: barcode resolution rate + TestFlight pipeline
`labels: ci, phase-2`

Measure over 2 weeks: % of scans resolved (local or OFF) for regularly bought products; target ≥ 90% after one-time manual entries. Enable `testflight` CI job on tags.

**Acceptance criteria**
- [ ] Scan log (local only) shows ≥ 90% resolution
- [ ] `v0.2.0` tag produces a TestFlight build automatically

Refs: §1.3, §11


## Phase 3 — Recipes, analytics, adaptive TDEE


### 31. Recipes: model, editor, logging by grams or servings
`labels: persistence, ui, phase-3`

Recipe = food(source='recipe') + `recipe_ingredient` snapshots; editor with ingredient search, cooked total weight or servings count; per-100 g computed; log by grams or servings; "re-cook" updates weights.

**Acceptance criteria**
- [x] Core: `RecipeCalculator` tested (raw vs cooked weight, servings)
- [x] Editing a recipe does not change past diary entries
- [x] Duplicate recipe

Refs: FR-25


### 32. Saved meals (templates): create from a logged meal, log in one tap
`labels: persistence, ui, phase-3`

"Save as meal" from any meal section; Meals tab in Add Food; log all items (editable quantities before confirm).

**Acceptance criteria**
- [x] Items referencing deleted foods are flagged, meal still loggable
- [x] use_count/last_used ranking

Refs: FR-24


### 33. Core: weight trend EMA with outlier handling
`labels: core, phase-3`

`WeightTrend.compute(samples:alpha:)` — EMA α=0.1, carry-forward for missing days, down-weight day-over-day jumps > 2.5%.

**Acceptance criteria**
- [x] Tests: steady loss, plateau with noise, missing week, water-weight spike
- [x] Stored in `daily_metrics.weight_trend_kg`

Refs: §5.4.1 step 1


### 34. Core: adaptive TDEE estimator
`labels: core, phase-3`

Implements SPEC §5.4.1 steps 2–5: 14-day window, min 7 logged days, energy balance 7,700 kcal/kg, blend 0.7/0.3 with previous, clamp ±25% of formula baseline until high confidence, under-logging detection.

**Acceptance criteria**
- [x] Synthetic perfect-logging data recovers true TDEE within ±50 kcal
- [x] Missing days, spikes, under-logging scenarios tested
- [x] Confidence low/medium/high rules tested
- [x] Pure function; no DB or Health dependency

Refs: §5.4.1, FR-34


### 35. Weekly check-in: proposal, accept/edit/skip, history
`labels: ui, persistence, phase-3`

On configured weekday: sheet with weekly weight change vs goal, TDEE estimate + confidence, proposed kcal target; accept writes new `target` (origin='adaptive') and a `tdee_estimate` row; "How was this computed" sheet lists days used.

**Acceptance criteria**
- [x] Check-in reminder via local notification (opt-in)
- [x] History screen of past estimates and decisions
- [x] Every number tappable to its explanation

Refs: §5.4.1 steps 6–7


### 36. Mark day as complete + under-logging warnings
`labels: ui, phase-3`

Toggle on diary day ("Day fully logged") stored in `day_note.is_complete`; TDEE uses complete days or days with ≥ 3 entries; show gentle warning when intake is implausibly low vs estimate.

**Acceptance criteria**
- [x] Warning never lowers target automatically

Refs: §5.4.1 inputs


### 37. History calendar with adherence colors
`labels: ui, phase-3`

Month grid; each day colored by kcal vs target band (±5% green, ±15% yellow, else red; grey = not logged); tap → day.

**Acceptance criteria**
- [x] Uses the target effective on that day
- [x] Scroll performance fine for 2 years

Refs: FR-50


### 38. Charts: weight (raw + trend), body fat, kcal vs target, macros, steps, sleep, HR/HRV, water
`labels: ui, phase-3`

Swift Charts with 1w/1m/3m/1y ranges, scrubbing, averages line.

**Acceptance criteria**
- [x] Each dashboard tile opens its chart
- [x] Accessibility: audio graph / summary labels

Refs: FR-51


### 39. Weekly report
`labels: ui, core, phase-3`

Averages (kcal, macros, steps, sleep), best/worst day, intake vs estimated expenditure, weight trend change; shareable image (local render).

**Acceptance criteria**
- [x] Report for any past week
- [x] Numbers match charts to the unit

Refs: FR-52


### 40. App Intents: log favorite, quick-add kcal, remaining calories, log water
`labels: intents, phase-3`

`LogFavoriteFoodIntent`, `QuickAddCaloriesIntent`, `RemainingCaloriesIntent`, `LogWaterIntent` with Siri phrases and Shortcuts parameters.

**Acceptance criteria**
- [x] Works from Shortcuts app and Siri without opening the app
- [x] Writes go through the same repositories (HealthKit sync included)

Refs: FR-71


### 41. Duplicate foods merge tool and local backup rotation
`labels: persistence, phase-3`

Detect likely duplicates (same barcode or normalized name+brand) and merge (re-point entries, keep best data). Automatic weekly JSON backup, keep last 7 in app container.

**Acceptance criteria**
- [x] Merge is transactional and tested
- [x] Backups listed/restorable in Settings

Refs: FR-26, FR-62


### 42. Widgets (if time allows): kcal remaining ring, macros, today's metrics
`labels: ui, phase-3, nice-to-have`

WidgetKit small/medium/lock-screen; App Group shared DB read; timeline refresh after logging.

**Acceptance criteria**
- [x] Widget reflects a new entry within 1 min

Refs: FR-70 (SHOULD)


### 43. Phase 3 exit: 30-day success criterion + v1.0.0 release
`labels: ci, phase-3`

30 consecutive days of use; TDEE estimate shown with ≥ 14 days; tag `v1.0.0`, TestFlight build, README screenshots, SPEC change-log entry.

**Acceptance criteria**
- [ ] All §1.3 success criteria met and recorded in the release notes

Refs: §1.3, §13
