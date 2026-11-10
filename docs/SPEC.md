# Personal Nutrition & Health Tracker — Product & Technical Specification

| Field | Value |
|---|---|
| Document version | 1.1 (v1.0 feature-complete) |
| Date | 2026-11-10 |
| Status | **Approved** — development starts with Phase 0. Changes go through PRs to `docs/SPEC.md` with a change-log entry. |
| Name | **Vitalion** (called Nutrilog until November 2026; the bundle ID `hr.ivanjuric.nutrilog` stays) |
| Audience | Single owner/developer; open-source contributors later |
| License | Code: **MIT**; bundled/derived data keeps its own license (CC0 for USDA subset; ODbL attribution for OFF) |

> **Decisions so far**
> - **D1 — Stack:** native Swift / SwiftUI iOS app.
> - **D2 — Backend:** none in v1 (local-first, sync-ready schema); self-hosted Supabase or PocketBase + web client in phase 4.
> - **D3 — v1 scope:** adaptive TDEE (MacroFactor-style) is a **MUST** for v1; micronutrients, widgets and Apple Watch are **not** v1 requirements (widgets SHOULD, Watch/micros COULD).
> - **D4 — Platform target:** **iOS 26.0+**, Swift 6.x, Xcode 26. No legacy fallbacks (VisionKit scanner, Swift Charts, SwiftData/GRDB, App Intents, Liquid Glass UI all assumed available).
> - **D5 — Devices:** Withings scale (weight, body fat → Apple Health) + Apple Watch (steps, active energy, sleep → Apple Health). Source priority: Apple Watch for steps/sleep/energy, Withings for weight/body composition. No Withings sleep or watch devices → Withings direct API stays optional.
> - **D6 — License:** MIT.
> - **D7 — Distribution:** Apple Developer Program membership → TestFlight builds via CI (90-day builds, auto-renewed), HealthKit background delivery enabled.
> - **D8 — Persistence:** GRDB.swift (SQLite + FTS5), explicit versioned migrations, schema mirrored to Postgres in phase 4.
> - **D9 — Extra v1 tiles:** water intake (logged in-app, written to Health), body fat % (Withings via Health), resting heart rate + HRV (Apple Watch via Health). OFF contribution stays COULD (phase 4).
>
> **v1** = phases 1–3 of the roadmap (§13).
>
> **How to read this document.** Decisions D1–D9 are final for v1. Minor defaults still adjustable during Phase 0 are listed in §14. Requirements use MoSCoW priorities: **MUST** (v1), **SHOULD** (v1 if time allows), **COULD** (later), **WON'T** (explicitly out of scope).

---

## 1. Vision & Goals

A free, ad-free, open-source, privacy-first personal app that answers one question every day: *"How am I doing?"* — combining what I ate (calories, macros) with how my body responded (weight trend, steps, sleep) in one place.

### 1.1 Goals
1. **Fast daily food logging** — barcode scan, search, recents, favorites, saved meals, custom foods and recipes. Logging a typical meal should take under 15 seconds.
2. **Calories + macronutrients** tracked against personal daily targets.
3. **Body & activity context from Apple Health** — weight (from Withings or any scale that writes to Apple Health), steps, sleep duration, active energy.
4. **Local-first, no account required**, with the data model designed so a web client can be added later.
5. **iOS first**, web later; both sharing one data store.
6. **Open source on GitHub (public repo)** with a reproducible build and no secrets in the repository.

### 1.2 Non-goals (WON'T)
- Monetization of any kind: no ads, no subscriptions, no analytics/telemetry, no third-party SDKs that phone home.
- Social features, coaching, community food database moderation.
- Medical advice or diagnosis. The app will carry a standard "not a medical device" disclaimer.
- Android app (not planned; a web client covers non-iOS access).
- Multi-user / family accounts (single user; may be revisited).

### 1.3 Success criteria for v1
- 30 consecutive days of real daily use by the owner without reverting to another app.
- ≥ 90% of scanned barcodes of regularly purchased products resolve (after one-time manual entry for misses).
- Daily dashboard shows intake, weight (7-day trend), steps and sleep for "today" with no manual input besides food.

---

## 2. Market Research

### 2.1 Landscape summary (Nov 2026)

The category has split into three groups: large-database "all-rounders" (MyFitnessPal, Lose It!, Yazio, Lifesum, FatSecret), accuracy/data-focused apps (Cronometer), and adaptive-coaching apps (MacroFactor, Carbon Diet Coach). A new wave of AI-photo-logging apps (Cal AI–style, Fitia) competes on logging speed. In parallel, well-maintained open-source trackers now exist (OpenNutriTracker, Caloryn) that prove the "Open Food Facts + local storage + HealthKit" stack works.

Commonly cited pain points with incumbents that this project should avoid:
- Free tiers shrinking (MyFitnessPal moved barcode scanning behind a paywall in 2022 and limited free logging further in 2024).
- Static calorie targets that never adapt to real weight change (MacroFactor's main differentiator is adaptive TDEE).
- Inconsistent crowd-sourced database entries (five different calorie counts for the same food).
- Divisive redesigns and slower workflows.

### 2.2 Competitor matrix

| App | Model | Barcode | Food DB | Macros | Micros | Apple Health | Weight trend / adaptive TDEE | Recipes / saved meals | Web | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| **MyFitnessPal** | Freemium (~$20/mo premium) | Premium only | Largest (crowd-sourced, noisy) | Yes | Partial | Read/write | Static target | Yes | Yes | AI photo/voice/text logging; 2026 redesign criticized |
| **Cronometer** | Freemium (Gold) | Free | Curated (USDA, NCCDB) — most accurate | Yes | Best in class (80+) | Read/write | Weight chart; no adaptive TDEE | Yes | Yes | Gold standard for data accuracy |
| **MacroFactor** | Paid (~$12/mo) | Yes | Verified + user | Yes | Yes | Read (weight, steps) | **Adaptive expenditure algorithm** (weekly check-in) | Yes | No | Science-driven, "non-judgmental" coaching |
| **Lose It!** | Freemium | Yes (free) | Large | Yes | Premium | Read/write | Static | Yes | Yes | Beginner-friendly, photo logging (Snap It) |
| **Yazio** | Freemium | Yes | Large (EU strong) | Yes | Premium | Read/write | Static | Yes | Yes | Good EU product coverage; fasting tracker |
| **Lifesum** | Freemium | Yes | Large | Yes | Premium | Read/write | Static | Yes | Yes | Diet plans, Sweden-based, EU coverage |
| **FatSecret** | Free (ads) + Premium | Yes | Large | Yes | Partial | Read/write | Static | Yes | Yes | Cheapest; ad-supported |
| **Fitia** | Freemium | Yes | Own + verified | Yes | Partial | Yes | Static | Meal planning | No | Newer entrant; strong meal plans |
| **OpenNutriTracker** (OSS, Flutter, GPL-3) | Free, no ads | Yes (OFF) | Open Food Facts + USDA FDC + German BLS via own OSS backend | Yes | Yes | Yes | Weight chart | Recipes, custom meals | No | Encrypted local storage, self-hostable backend; ~2.8k GitHub stars, active (last push Oct 2026) |
| **Caloryn** (OSS, SwiftUI/SwiftData) | Free | Yes (OFF) | Open Food Facts | Yes | Partial | Activity adjustment | Weight | Custom foods & recipes | No | iOS 26 target, optional iCloud sync, CSV export — closest architectural reference |

### 2.3 Feature takeaways for this project

| Keep (table stakes) | Differentiate / borrow | Deliberately skip |
|---|---|---|
| Barcode scan, text search, recents, favorites | **Unified daily view** of intake + weight + steps + sleep (most apps show nutrition and body data on separate screens) | Social feed, challenges |
| Custom foods, saved meals, recipes with per-serving math | **Weight trend smoothing** (exponential moving average) à la MacroFactor/Happy Scale | Paid "premium" nutrients |
| Daily/weekly totals, macro rings | **Adaptive TDEE estimate** from intake vs. weight trend (SHOULD, phase 3) | AI photo recognition (COULD, only if a free/local model is viable) |
| Apple Health read/write | **Croatian-market reality**: Open Food Facts has only ~3,600 Croatian products (Nov 2024, growing ~100/month) → the "barcode not found" path must be first-class, with one-tap manual nutrition entry and optional contribution back to OFF | Meal plans, diet programs |
| Export (CSV/JSON) | **Copy yesterday / copy meal**, "quick calories" entry | Gamification |

---

## 3. Data Sources Research

### 3.1 Packaged foods by barcode — Open Food Facts (OFF)
- **API**: `GET https://world.openfoodfacts.org/api/v2/product/{barcode}.json?fields=...` (v2 stable; v3 recommended for new projects). No API key. Requires a descriptive `User-Agent` header per OFF terms. Returns `status: 1` with a nested `nutriments` object (values per 100 g **and** per serving when available; energy in kJ and kcal; sodium in g).
- **License**: ODbL 1.0 (database) + Database Contents License. The app must display *"Contains information from Open Food Facts, contributed by Open Food Facts contributors"* and link back to the product page.
- **Coverage**: excellent for products sold in FR/DE/ES/IT and EU-wide brands (Lidl, Spar, Kaufland private labels often already present from AT/DE contributors); **thin for Croatia-only products** (Kraš, Podravka, Vindija, Dukat, etc. are partially present). Local community exists (`hr.openfoodfacts.org`, Croatian Slack channel).
- **Write-back**: authenticated POST can create/complete a product (photos + nutrition). Optional for this app (COULD) — gives back to the community and improves future scans.
- **Gotcha**: missing products return HTTP 200 with `status: 0`; treat `status` not HTTP code as the truth.
- **Search**: v2 search is filter-based; only the v1 search endpoint supports full-text search. Use OFF search as a secondary source for packaged foods only.

### 3.2 Generic/whole foods — USDA FoodData Central (FDC)
- **API**: `https://api.nal.usda.gov/fdc/v1/foods/search`, `/food/{fdcId}`, `/foods` (bulk, max 20 IDs). Data types: Foundation, SR Legacy, FNDDS (Survey), Branded.
- **License**: CC0 1.0 (public domain) — no attribution required (we will attribute anyway).
- **Rate limits**: registered key 1,000 req/hour/IP; `DEMO_KEY` 30/hour and 50/day. Exceeding blocks the key for 1 hour.
- **Critical for an open-source repo**: USDA deactivates any API key found in a public repository. Therefore the key must **never** be committed; see §10 for the three options (user-supplied key in Settings, CI secret injected at build, or a tiny proxy).
- **Local fallback**: FDC Foundation + SR Legacy are downloadable as CSV (~7–8k foods with full nutrient profiles). Bundling a curated subset (~1,500 common whole foods) in the app allows **offline search** and removes dependence on the API for generic foods. Decision: a subset is bundled and regenerated by `tools/build_food_index.py`.

### 3.3 Croatian/regional food composition
- Croatia has no public API-accessible food composition database. EuroFIR member tables (e.g. Slovenia's OPKP, Germany's BLS) exist but are license-restricted (BLS is paid; OpenNutriTracker ships it through their backend).
- **Plan**: rely on USDA for generic foods (nutritionally equivalent for most whole foods), OFF for packaged, and the user's own custom entries for local specialties (e.g. ajvar, kulen, štrukli). Custom entries are exportable so they can later be published as an optional community dataset in the repo (CC0).

### 3.4 Apple HealthKit
- Capability + `NSHealthShareUsageDescription` (read) and `NSHealthUpdateUsageDescription` (write) in Info.plist. Available on iOS; iPadOS 17+; not on macOS (relevant for the web/desktop story — Health data on the web will only come via sync from the phone).
- **Read types needed**: `stepCount`, `bodyMass`, `bodyFatPercentage`, `activeEnergyBurned`, `basalEnergyBurned`, `sleepAnalysis` (category; stages asleepCore/Deep/REM, awake, inBed), `restingHeartRate`, `heartRateVariabilitySDNN`, `dietaryWater` (to show water logged by other apps), `height`, `dateOfBirth`, `biologicalSex` (characteristics, for BMR).
- **Write types**: `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal`, `dietaryFiber`, `dietarySugar`, `dietarySodium`, `dietaryWater`, `bodyMass` and `bodyFatPercentage` (only when weight — and optionally body fat — is entered manually in our app; our own body samples are ignored when reading, so a manual weigh-in is never counted twice).
- **Resting HR / HRV**: Apple Watch writes one `restingHeartRate` sample per day and several `heartRateVariabilitySDNN` samples (mostly overnight); show the day's resting HR and the overnight HRV average, plus a 7-day trend — these are recovery context, not targets.
- **Behaviors to design for**:
  - Read authorization status is opaque (denied is indistinguishable from "no data") → UI must say "No data found — check Health permissions" rather than assume denial.
  - Steps: use `HKStatisticsCollectionQuery` with `.cumulativeSum` and `.separateBySource` disabled so Apple's de-duplication across iPhone + Watch applies.
  - Sleep: sum `asleep*` samples whose *end* falls in the "night ending on date D" window (e.g. 18:00 D-1 → 18:00 D), using **Apple Watch as the only sleep source** (D5); iPhone-only "in bed" estimates are ignored when Watch data exists for that night. Stages (core/deep/REM/awake) shown as a secondary breakdown.
  - Weight: take the earliest sample of the day (morning Withings weigh-in) as the day's value; keep all samples for the trend. Body fat % read from the same Withings sample when present.
  - Use `HKObserverQuery` + background delivery (`.hourly` is enough) to refresh the dashboard without opening Health.
  - **Avoid write loops**: never write back samples the app read from Health; tag our own samples with metadata (`HKMetadataKeyExternalUUID` = our entry id) so edits/deletes update the same Health sample.

### 3.5 Withings
- **Path for v1 (D5)**: Withings app → Apple Health → our app. Zero code; covers weight and body composition from the scale. Steps, energy and sleep come from Apple Watch via Health, so Withings direct API has no v1 use case.
- **Direct Withings API (COULD, phase 4 with the web client)**: OAuth2 authorization code flow (`account.withings.com/oauth2_user/authorize2`, token at `/oauth2/token`), scopes `user.metrics,user.activity`, measures via `wbsapi.withings.net/measure?action=getmeas` (type 1 = weight kg, 6 = fat %, 76 = muscle mass, 77 = hydration, 88 = bone mass). Quirks: parameter is `client_secret` but Withings also uses `action=` style requests and wraps responses in `{status, body}`. Needs a server-side callback URL → only sensible once a backend exists (web phase). Known Withings issue: multi-user scales can mix data in Health — not a concern for single-user.

---

## 4. Users & Core Scenarios

Single user (the owner). Representative daily flows:

1. **Morning**: open app → dashboard already shows last night's sleep, this morning's weight (synced from Withings via Health), 7-day weight trend, and yesterday's steps.
2. **Breakfast**: tap "+" on Breakfast → "Recent" shows the usual oats + milk → adjust grams → done (≤ 10 s).
3. **Shopping / new product**: scan barcode → found in OFF → confirm serving → log. Not found → "Create food" pre-filled with barcode → type kcal/P/C/F from label (per 100 g) → save (available for all future scans; optionally contribute to OFF).
4. **Cooking**: create recipe "Chili" from ingredients → total weight 1,800 g → log 350 g portion → macros computed per gram.
5. **Evening**: check remaining calories/macros; log water (optional); widget on Home Screen shows ring.
6. **Weekly**: review weekly averages: intake vs. weight trend → adaptive TDEE estimate (phase 3) suggests target adjustment.
7. **Anywhere**: on laptop, open web app to review history, bulk-edit, export CSV (phase 4).

---

## 5. Functional Requirements

### 5.1 Food diary (MUST)
- FR-1 Diary organized by day and meal slot (Breakfast, Lunch, Dinner, Snacks; slots configurable).
- FR-2 Each entry = food reference + quantity + unit (g, ml, serving, piece); nutrients computed from per-100 g base.
- FR-3 Edit, delete, move entry between meals/days; swipe actions.
- FR-4 "Copy meal from yesterday / from date" and "copy whole day".
- FR-5 Quick-add calories (and optional macros) without a food.
- FR-6 Day summary: kcal consumed, remaining, P/C/F grams and % of target; fiber, sugar, sodium (sat. fat SHOULD).
- FR-7 Notes per day (free text, e.g. "cheat day", "sick").
- FR-8 Snap or describe a meal (SHOULD): a photo and/or a sentence becomes a list of foods with amounts to review, correct and log in one tap. The estimate is made on the device by the Apple Intelligence model (Foundation Models; a photo needs iOS 27) and logged as foods of their own (marked "Estimated by Apple Intelligence", reused when the same estimate comes again), so an entry's amount can be edited later and the meal saved as a meal. Where the model isn't available, the text, or the labels of the on-device image classifier, are matched to foods on the phone and logged as those foods. Nothing is sent anywhere.

### 5.2 Barcode scanning (MUST)
- FR-10 Scan EAN-13, EAN-8, UPC-A/E, Code-128 using **VisionKit `DataScannerViewController`**; continuous scanning, haptic on detect, torch toggle. (AVFoundation fallback not needed on iOS 26 hardware.)
- FR-11 Lookup order: ① local DB (custom foods & cached OFF products) → ② Open Food Facts API → ③ (COULD) USDA Branded by GTIN.
- FR-12 Found: show product card (name, brand, image, per-100 g & per-serving nutrients, Nutri-Score if present, data-quality warning if key nutrients missing) → choose quantity → log. Product cached locally.
- FR-13 Not found: create custom food pre-filled with barcode; optional photo of label for reference; (COULD) submit to OFF.
- FR-14 Manual barcode entry (type digits) for damaged codes.

### 5.3 Food search & database (MUST)
- FR-20 Unified search box across: custom foods, recipes, saved meals, bundled generic foods (USDA subset), cached products; then online (OFF search, USDA search) with clear source badges.
- FR-21 Search is diacritic- and case-insensitive; supports Croatian and English names (custom foods can have both).
- FR-22 "Recent" (last 50 logged) and "Favorites" (starred) lists; frequency-ranked suggestions per meal slot (e.g. breakfast foods first in the morning).
- FR-23 Custom food: name, brand, barcode(s), serving definitions (e.g. "1 slice = 25 g"), nutrients per 100 g (kcal, P, C, F mandatory; fiber, sugar, sat. fat, sodium optional; micronutrients COULD, post-v1 — the schema reserves a JSON `micros` column so adding them later needs no migration), source note.
- FR-24 Saved meals (a named list of foods with amounts; created from scratch or from a logged meal, editable, loggable in one tap, amounts editable at log time).
- FR-25 ~~Recipes: ingredients + cooked total weight (or number of servings) → nutrients per 100 g / per serving; log by grams or servings; re-cook with changed weights.~~ Removed in favour of saved meals (issue #68): the app has foods and meals only; existing recipes became ordinary custom foods. Mentions of recipes elsewhere in this document are historical.
- FR-26 Verified/curated flag and "last used" timestamp; duplicates merge tool (SHOULD).

### 5.4 Targets & profile (MUST)
- FR-30 Profile: height, date of birth, sex, activity level; weight read from Health (manual fallback).
- FR-31 Calorie target: computed (maintenance ± goal rate) or manual override. Maintenance is the 30-day average of Health total energy (active + resting; at least 7 usable days, days below 60 % of the median dropped as partial wear); without it, Mifflin-St Jeor BMR × activity.
- FR-32 Macro targets as grams or % with validation that % sum to 100; optional different targets per weekday (training vs. rest day) (SHOULD).
- FR-33 Goal modes: lose / maintain / gain with weekly rate; app shows implied deficit/surplus.
- FR-34 (**MUST**, phase 3) **Adaptive expenditure**: estimate TDEE from logged intake and smoothed weight change; surface as "estimated maintenance" with a confidence indicator; weekly check-in proposes a new calorie target with one-tap apply. Algorithm in §5.4.1.

#### 5.4.1 Adaptive TDEE algorithm (v1)
Inputs: daily `kcalIn` (diary totals; days with < 3 entries and no "complete day" flag are treated as missing), daily morning `weightKg` (Health), user goal rate.

1. **Weight trend**: exponential moving average of weight, α ≈ 0.1 (≈ 10-day half-life trend, Happy Scale/MacroFactor-like). Missing days carry the previous trend value forward; outliers (> 2.5% jump day-over-day) are down-weighted.
2. **Window**: rolling 14 days (minimum 7 logged days to show an estimate; confidence grows to "high" at 21+ days with ≥ 80% logged days).
3. **Energy balance**: `ΔE = (trend_end − trend_start) × 7,700 kcal/kg` over the window.
4. **Estimate**: `TDEE_est = mean(kcalIn over logged days) − ΔE / windowDays`.
5. **Smoothing**: blend with the previous week's estimate (0.7 new / 0.3 old) to avoid jumps; clamp to ±25% of the baseline (FR-31 maintenance: measured Health energy, else Mifflin-St Jeor × activity) until confidence is high.
6. **Check-in** (configurable weekday, default Monday): show actual weekly weight change vs. goal rate, new TDEE estimate, and the proposed target `TDEE_est − goalRateKgPerWeek × 7,700 / 7`. User accepts, edits or skips.
7. **Transparency**: every number tappable to a "how was this computed" sheet listing the days used and their kcal/weight.

Unit tests cover: perfect-logging synthetic data (recovers the true TDEE within ±50 kcal), missing days, water-weight spikes, under-logging detection (if intake is implausibly low vs. estimate, warn rather than lower the target).

### 5.5 Health & body data (MUST)
- FR-40 Request HealthKit read permissions for steps, weight, body fat %, sleep, active energy, basal energy; write permission for dietary nutrients and body mass.
- FR-41 Dashboard tiles for today: steps, sleep duration (hours:minutes, plus in-bed vs. asleep and stage breakdown), weight (latest + trend + trend Δ vs. 7 days ago; the trend is the EMA of §5.4.1 step 1, the same one the charts and the adaptive TDEE use), body fat %, active energy, resting heart rate, overnight HRV, water. Tiles are reorderable/hideable.
- FR-42 Manual weight entry (writes to Health unless disabled).
- FR-43 Write each diary entry's nutrients to Health as `dietary*` samples; keep in sync on edit/delete; global toggle to disable writing.
- FR-44 Background refresh via observer queries; manual pull-to-refresh.
- FR-45 (SHOULD) Optional "activity-adjusted target" (add a configurable % of active energy to the day's target) — off by default to avoid double counting with TDEE activity factor.
- FR-46 (**MUST**, D9) **Water intake**: quick-add buttons (e.g. 200 / 330 / 500 ml, configurable), daily goal, written to Health as `dietaryWater`; also sums water logged by other Health apps.
- FR-47 (**MUST**, D9) **Body fat %** from Withings via Health: latest value + trend chart alongside weight.
- FR-48 (**MUST**, D9) **Resting HR & HRV (SDNN)** from Apple Watch via Health: today's value, 7-day average and deviation (e.g. "HRV 12% below your 30-day average"). Informational only; no medical interpretation.

### 5.6 Analytics & history (SHOULD)
- FR-50 Calendar/history view with per-day kcal and adherence color.
- FR-51 Charts (Swift Charts): weight (raw + trend), daily kcal vs. target, macro distribution, steps, sleep — 1w / 1m / 3m / 1y.
- FR-52 Weekly report: averages, best/worst day, intake vs. estimated expenditure.
- FR-53 Correlations (COULD): sleep vs. next-day intake, steps vs. weight trend.

### 5.7 Data portability (MUST)
- FR-60 Export all data as JSON (full fidelity, versioned schema) and CSV (diary, weights); share sheet / Files.
- FR-61 Import from own JSON (restore) ; (COULD) import MyFitnessPal/Cronometer CSV exports.
- FR-62 Automatic local backup rotation (last 7 exports in app container) (SHOULD).

### 5.8 iOS platform features
- FR-70 Home Screen & Lock Screen widgets: calories remaining ring, macro bars, today's steps/sleep/weight (SHOULD, not required for v1).
- FR-71 Siri Shortcuts / App Intents: "Log 1 coffee", "How many calories do I have left" (SHOULD).
- FR-72 Apple Watch companion: view remaining kcal, quick-add favorites (COULD, post-v1).
- FR-73 Dark mode, Dynamic Type, VoiceOver labels (MUST — accessibility is cheap in SwiftUI if done from the start).
- FR-74 UI language English; Croatian localization (COULD).

### 5.9 Web client (phase 4, SHOULD)
- FR-80 Responsive web app (read + full edit of diary, foods, recipes; charts; export). No barcode camera required (keyboard entry allowed; (COULD) browser barcode scanning via `BarcodeDetector` API where supported).
- FR-81 Health data (steps/sleep/weight) visible on web via sync from iOS; no direct HealthKit on web.
- FR-82 Same data model and sync protocol as iOS; single-user auth (passkey or long-lived token).

---

## 6. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-1 **Privacy** | No analytics, no crash-reporting SDKs by default (optional, user-enabled Apple-only crash logs). Only outbound calls: OFF, USDA (and sync backend if enabled). All listed in README and Settings → "Network". |
| NFR-2 **Offline-first** | All logging, search of local/bundled foods, targets, charts work with no network. Online lookups degrade gracefully. |
| NFR-3 **Performance** | Cold start < 1.5 s on iPhone 12-class; search results < 100 ms for local; scan-to-card < 1 s with network. |
| NFR-4 **Data integrity** | Entries store a *snapshot* of nutrients at log time so later edits to a food don't rewrite history (with optional "re-apply to past entries"). Schema migrations are versioned and tested. |
| NFR-5 **Security** | No secrets in repo. Local DB encrypted at rest via iOS Data Protection (complete until first unlock). Any backend uses TLS, single-user auth, and RLS. |
| NFR-6 **Licensing** | Respect ODbL attribution (OFF) and keep attribution for USDA; third-party Swift packages must be MIT/Apache/BSD-compatible with the chosen app license. |
| NFR-7 **Maintainability** | Modular Swift packages (Core, Persistence, HealthKitClient, FoodSources, UI). ≥ 70% unit-test coverage on Core (nutrient math, TDEE, date windows). |
| NFR-8 **Compatibility** | **iOS 26.0+** only (D4). Single-version target removes availability checks and allows the newest SwiftUI, SwiftData, HealthKit and App Intents APIs; the Liquid Glass design language is adopted natively. |
| NFR-9 **Reproducible build** | Clone → open Xcode → set team → run. Documented in README; CI builds and tests on every PR. |

---

## 7. Architecture

### 7.1 Options considered

| Option | Stack | Pros | Cons | Web path |
|---|---|---|---|---|
| **A. Native + iCloud** | SwiftUI, SwiftData (or GRDB), CloudKit sync | Zero backend, free, best iOS integration (HealthKit, widgets, Watch, App Intents), fastest to ship | CloudKit is Apple-only — web client would need CloudKit JS (awkward) or a later migration | Hard |
| **B. Native iOS + own backend** | SwiftUI + local store on device; self-hosted **Supabase** (Postgres + Auth + REST/Realtime) or **PocketBase** (single Go binary + SQLite); web in SvelteKit/React | Clean path to web; still fully native iOS; Supabase is OSS and self-hostable (Docker) or free tier hosted | Must design sync (conflict rules), run/maintain a server, auth | Natural |
| **C. Cross-platform** | Flutter (as OpenNutriTracker) or React Native / Expo or Kotlin Multiplatform | One codebase for iOS + web | HealthKit, widgets, Watch, App Intents via plugins — weaker and laggier; web output of Flutter is heavy; less "Apple-native" feel | Shared code, but mobile-centric |

### 7.2 Decision (D1 + D2): Option B in two steps
**Confirmed.** build v1 as a **native SwiftUI app with a local-first store and a sync-ready data model** (every record has `uuid`, `createdAt`, `updatedAt`, `deletedAt` soft-delete, and `revision`). Ship phases 1–3 with **no backend at all** (optionally CloudKit *device-to-device* sync as a convenience). In phase 4 add a self-hosted Supabase/PocketBase backend and a web client; sync is last-writer-wins per record with the iOS app as the only writer of Health-derived rows.

Why not A: it locks the web story. Why not C: your three hardest integrations (HealthKit, barcode scanning with VisionKit, widgets) are exactly where cross-platform frameworks are weakest, and the web client is a secondary, later target where a separate lightweight web app is fine.

### 7.3 iOS app structure (Option B, v1)
```
Vitalion/
├── App/                      # SwiftUI app entry, DI container, navigation
├── Packages/
│   ├── Core/                 # Domain models, nutrient math, TDEE, date windows (pure Swift, 100% testable)
│   ├── Persistence/          # GRDB (SQLite + FTS5); migrations; repositories; export/import
│   ├── FoodSources/          # OpenFoodFactsClient, USDAClient, BundledFoodIndex
│   ├── FoodLookup/           # Barcode lookup pipeline + OFF cache policy, saving copies of online foods (Persistence + FoodSources)
│   ├── HealthKitClient/      # Authorization, queries, writers, observers
│   ├── Scanner/              # VisionKit DataScannerViewController wrapper
│   └── DesignSystem/         # Colors, typography, components, charts
├── Widgets/                  # WidgetKit extension (reads a snapshot of today from the App Group container)
├── Shared/                   # Code compiled into the app and the widget extension
│                             # App Intents (Siri/Shortcuts) live in App/Sources/Intents: they run in the app process
├── Resources/                # Bundled food index (SQLite or JSON), licenses
└── Tests/                    # Unit + UI tests
```
- **Persistence (D8): GRDB.swift** — SQLite with FTS5 full-text search over foods (unicode61 tokenizer with `remove_diacritics 2` so "čokolada" matches "cokolada"), explicit numbered migrations in `Persistence/Migrations/`, `DatabasePool` for concurrent reads, `ValueObservation` driving SwiftUI views. SQL schema is kept portable (no SQLite-only types) for the phase-4 Postgres mirror.
- **Concurrency**: Swift 6 strict concurrency, actors for HealthKit and network clients.
- **Networking**: `URLSession` + `Codable`; no third-party HTTP library. Retry/backoff; caching of OFF product JSON for 30 days.

### 7.4 Sync & backend (phase 4)
- Postgres schema mirrors the SQLite schema (same table/column names). Row-level security on `user_id`; single user.
- Sync: pull `updated_at > last_sync`, push local dirty rows; conflicts resolved by `updated_at` (LWW) except diary entries where both versions are kept and flagged (rare for single user).
- Health-derived daily metrics (`daily_metrics`) are pushed by iOS only; web is read-only for them.
- Web: SvelteKit or Next.js, Tailwind, Chart library; PWA installable.

---

## 8. Data Model (logical)

```
Food
  id (uuid), name, nameLocal?, brand?, source (custom|off|usda|bundled|recipe), sourceId?,
  barcodes [string], per100g {kcal, proteinG, carbsG, fatG, fiberG?, sugarG?, satFatG?, sodiumMg?, ...micros?},
  servings [{label, grams}], defaultServingId?, imageURL?, isFavorite, lastUsedAt, useCount,
  dataQuality (complete|partialMacros|energyOnly), notes?, createdAt, updatedAt, deletedAt?, revision

Recipe (extends Food with source=recipe) — removed, see FR-25; `source=recipe` and the `recipe_ingredient` table remain only as legacy schema
  ingredients [{foodId, grams, snapshotPer100g}], cookedWeightG?, servingsCount?

MealTemplate ("saved meal")
  id, name, items [{foodId, grams}], mealSlotHint?, lastUsedAt, useCount

DiaryEntry
  id, date (YYYY-MM-DD, local), mealSlot, foodId?, grams, servingLabel?,
  nutrientSnapshot {kcal, proteinG, carbsG, fatG, fiberG?, sugarG?, satFatG?, sodiumMg?},
  quickAdd (bool), healthKitSampleUUIDs [..], note?, createdAt, updatedAt, deletedAt?, revision

DayNote { date, text }

DailyMetrics (from HealthKit, one row per date)
  date, steps?, activeKcal?, basalKcal?, sleepAsleepMin?, sleepInBedMin?, sleepStages?{core,deep,rem,awake},
  weightKg? (first of day), bodyFatPct?, weightTrendKg? (EMA, computed), restingHR?, hrvSDNNms? (overnight avg),
  waterMl? (sum incl. other apps), sourceSummary, fetchedAt

WaterEntry { id, timestamp, ml, healthKitUUID?, createdAt, updatedAt, deletedAt?, revision }

WeightEntry (manual or imported) { id, timestamp, kg, bodyFatPct?, source, healthKitUUID? }

Profile { heightCm, birthDate, sex, activityLevel, goalMode, goalRateKgPerWeek, unitSystem }
Targets { effectiveFrom (date), kcal, proteinG, carbsG, fatG, fiberG?, perWeekdayOverrides? }
Settings { mealSlots[], healthWriteEnabled, offContributionEnabled, usdaApiKey (Keychain), theme, ... }
```
Key rules: `DiaryEntry.nutrientSnapshot` is the source of truth for history; `Food.per100g` is the source for *new* entries. `DailyMetrics` is a cache of Health — Health remains the system of record and the row can always be recomputed.

---

## 9. Barcode Lookup Pipeline (detail)

```
scan(code)
  ├─ normalize (strip leading zeros for UPC-A→EAN-13, validate checksum)
  ├─ local: Food where barcodes contains code            → hit → ProductCard(local)
  ├─ cache: OFFProductCache(code, age < 30d)              → hit → ProductCard(off)
  ├─ network: OFF v2 /product/{code}?fields=product_name,brands,quantity,serving_size,
  │           serving_quantity,nutriments,nutriscore_grade,image_front_small_url,
  │           ingredients_text,allergens_tags,last_modified_t
  │     status==1 && has energy+macros → ProductCard(off), cache
  │     status==1 && missing macros    → ProductCard(off, dataQuality=partial) with "Complete nutrition" CTA
  │     status==0                       → NotFound
  └─ NotFound → CreateFood(prefilledBarcode) [+ optional OFF contribution later]
```
Nutrient mapping notes: prefer `energy-kcal_100g`, else `energy_100g` (kJ) / 4.184; `salt_100g` → sodium = salt × 400 mg; `serving_quantity` is in g/ml when present, else parse `serving_size` string; some products only have per-serving values — scale to 100 g when `serving_quantity` known, otherwise store per-serving with `dataQuality=partial`.

---

## 10. Secrets, Keys & Open-Source Hygiene

- **Open Food Facts**: no key; set `User-Agent: Vitalion/1.0 (github.com/memphin/vitalion)`.
- **USDA FDC key** — three supported modes (choose per build):
  1. **User-provided** (default for forks): Settings → paste your own free key (stored in Keychain). The app works without it using the bundled subset + OFF.
  2. **CI-injected**: GitHub Actions secret written into an `.xcconfig` at build time; `.xcconfig` is git-ignored; only the owner's TestFlight/personal builds get it.
  3. **Proxy** (phase 4): backend holds the key; web and iOS call the backend.
- `.gitignore`: `*.xcconfig` (except template), `*.mobileprovision`, `fastlane/report.xml`. Add `gitleaks` pre-commit hook and CI step.
- Withings `client_secret` (if ever used) lives only on the backend.

---

## 11. Distribution (personal use)

| Path | Cost | Notes |
|---|---|---|
| Free Apple ID sideload via Xcode | €0 | App expires every 7 days, max 3 apps — impractical for daily use |
| **Apple Developer Program** (TestFlight / personal App Store Connect, ad-hoc) | $99/yr | **Chosen (D7).** Required for HealthKit background delivery, widgets signing, 90-day TestFlight builds auto-renewed by CI. |
| Public App Store listing | $99/yr (same) | Optional; HealthKit apps face stricter review (privacy policy URL required). Not needed for personal use |
| AltStore / sideloading tools | €0 | Also 7-day refresh unless paid account |

CI: GitHub Actions `macos-latest` running `xcodebuild test` on PRs; `v*` tags also archive and upload to TestFlight with `xcodebuild -exportArchive` and automatic cloud signing (secrets: App Store Connect API key, team ID; no certificates in the repo). Setup: `docs/RELEASING.md`.

---

## 12. Open-Source Project Setup

- **License (D6): MIT** for all code. Bundled datasets keep their own licenses: the USDA-derived subset is CC0 and committed to the repo; OFF product data is cached only on device and never committed (ODbL attribution shown in-app). Third-party Swift packages must be MIT/Apache/BSD.
- Repo layout: `README.md` (screenshots, features, build steps), `LICENSE`, `CONTRIBUTING.md`, `PRIVACY.md` (what leaves the device), `docs/SPEC.md` (this document), `docs/ADR/` (architecture decision records), `.github/workflows/ci.yml`, issue templates.
- Branching: `main` protected; feature branches; squash merges; semantic version tags `v1.0.0`.
- Project board with the phases below as milestones.

---

## 13. Roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| **0. Foundation** (1–2 wks) | Repo, CI, license, module skeleton, GRDB schema v1 + migrations, DesignSystem, bundled USDA subset generation script (Python, in `tools/`) | App launches; tests green in CI |
| **1. MVP diary** (3–4 wks) | Diary, meal slots, custom foods, servings, recents/favorites, local & bundled search (FTS5), targets & profile, day summary, JSON/CSV export | Owner logs 7 consecutive days |
| **2. Barcode + online sources + Health** (4–5 wks) | VisionKit scanner, OFF lookup pipeline, product cache, create-from-barcode, USDA search (user key), HealthKit read (steps, sleep + stages, weight, body fat %, energy, resting HR, HRV, water) with background refresh, HealthKit write of nutrients and water, dashboard tiles, manual weight, water quick-add | ≥ 90% of regular products resolve; dashboard complete with no manual input |
| **3. Recipes, meals, analytics, adaptive TDEE** (4–5 wks) | Recipes, saved meals, copy day/meal, history calendar, Swift Charts, weekly report, weight trend EMA, **adaptive TDEE + weekly check-in (§5.4.1)**, App Intents; widgets if time allows | 30-day success criterion met; TDEE estimate shown with ≥ 14 days of data |
| **4. Backend + web** (4–6 wks) | Self-hosted Supabase/PocketBase, sync engine, auth, SvelteKit web app (diary, foods, recipes, charts, export), optional Withings direct API, optional OFF contribution | Edit on web → appears on phone (and vice versa) |
| **5. Polish / nice-to-haves** | Widgets (if not done in 3), Watch app, Croatian localization, micronutrients, MFP/Cronometer import, photo-based logging if a free/local model is viable | — |

Estimates assume part-time (evenings/weekends) solo development by someone comfortable with Swift; roughly halve them for full-time work.

---

## 14. Adjustable Defaults (non-blocking)

All blocking decisions are made (D1–D9). The following defaults may be changed during Phase 0 without a spec revision:

1. **Units**: metric only (kg, cm, g, ml, kcal); kJ display off by default.
2. **App name & bundle ID** (working: Vitalion, `hr.ivanjuric.nutrilog`).
3. **Water goal default** (assume 2,500 ml) and quick-add sizes.
4. **Contribute scans back to Open Food Facts** — COULD, phase 4, needs an OFF account.
5. **Phase 4 hosting**: self-hosted (home server / VPS) vs. hosted free tier — decide at end of phase 3.
6. **Croatian UI localization** — COULD, phase 5.

## 15. Appendix — API Quick Reference

| Source | Endpoint | Auth | Limits | License |
|---|---|---|---|---|
| Open Food Facts | `https://world.openfoodfacts.org/api/v2/product/{barcode}.json?fields=…` | None (User-Agent) | Fair use; ~100 req/min for product reads documented | ODbL 1.0 + DbCL |
| Open Food Facts search (full text) | `https://world.openfoodfacts.org/cgi/search.pl?search_terms=…&json=1` (v1) | None | ~10 req/min for search | ODbL |
| Open Food Facts write | `POST /cgi/product_jqm2.pl` (v2) / v3 product write | OFF user/password | — | Contributions ODbL |
| USDA FDC | `https://api.nal.usda.gov/fdc/v1/foods/search?query=…&api_key=…` | API key (free) | 1,000/h/IP; DEMO_KEY 30/h, 50/day | CC0 1.0 |
| Apple HealthKit | `HKHealthStore` (on-device) | User permission | — | — |
| Withings | `https://account.withings.com/oauth2_user/authorize2`, `https://wbsapi.withings.net/measure?action=getmeas` | OAuth2 (needs server callback) | Per developer app | Withings ToS |

---

*Change log*
- 1.6 — owner request: simpler logging with "Snap or describe a meal" (FR-8). Photo logging moves from "COULD, only if a free/local model is viable" (§3, §13 phase 5) to SHOULD, built on the free on-device Apple Intelligence model, with matching against local foods as the fallback. No new network destination (2026-11-10)
- 1.3 — owner feedback (issues #62–#67, #69, #70): the sleep tile shows only time asleep (stages in its detail); a daily step goal colours step bars (green / orange / red) and the water goal colours water (red / green); Active energy is merged into one Total energy tile drawn as resting + active; profile weight is read-only (latest weigh-in); the dashboard is arranged in Settings → Dashboard and Today has no toolbar buttons. Supersedes the tile list of FR-41 where they differ (2026-11-10)
- 1.4 — owner feedback (issues #72–#74): the sleep tile shows the time asleep as "7h 5min" with its 7-day bars, coloured by a sleep goal (Settings → Daily goals; green at the goal, orange up to an hour short, red further below); the weight tile shows the weight and its chart only; the HRV and resting heart rate values are coloured against the 30-day average (HRV: green at or above, orange up to 10% below, red further; resting heart rate: green at or below, orange up to 5% above, red further) (2026-11-10)
- 1.5 — owner feedback: the Total energy tile shows the total and the active part only (resting stays in its detail); the steps tile no longer writes its goal; weight is coloured by the profile goal against the mean of the 7 days before (lose: green at or below, orange up to 0.5 kg above, red further; gain: mirrored; maintain: no colour); body fat likewise (green at or below, orange up to 0.5 points above, red further); water is red below 80% of its goal, orange from there, green at the goal (2026-11-10)
- 1.2 — recipes removed in favour of saved meals, which can now be created and edited as a list of foods with amounts (issue #68); migration 008 turns recipe foods into custom foods (2026-11-10)
- 1.1 — phase 3 implemented (recipes, saved meals, weight trend, adaptive TDEE and weekly check-in, history calendar, charts, weekly report, App Intents, duplicate merge and backups, widgets). Clarifications made while building it: FR-41's weight tile uses the §5.4.1 trend (α = 0.1) instead of a separate 7-day EMA, so every screen shows one trend; the trend's outlier rule compares a weigh-in with the previous accepted one (at most 3 days earlier) and accepts a jump that the next weigh-in confirms; the estimate also needs ≥ 2 weigh-ins and a trend spanning ≥ 7 days of the window; "medium" confidence = ≥ 10 logged days and ≥ 4 weigh-ins; proposed targets never go below 1,200 kcal and are not lowered while under-logging is suspected; widgets read a snapshot written by the app rather than the database; App Intents are part of the app target (2026-11-10)
- 1.0 — approved baseline; draft markers removed (2026-11-09)
- 0.1 — initial research + draft (2026-11-09)
- 0.4 — D7 Developer Program/TestFlight, D8 GRDB, D9 water + body fat % + resting HR/HRV tiles added as MUST (FR-46–48, HealthKit types, data model); phase 2 estimate adjusted; all blocking questions closed (2026-11-09)
- 0.3 — D4 iOS 26 target, D5 devices (Withings scale + Apple Watch) with source priorities, D6 MIT license; open questions reduced to 7 (2026-11-09)
- 0.2 — decisions D1–D3 recorded; adaptive TDEE promoted to MUST with algorithm (§5.4.1); roadmap and open questions updated (2026-11-09)
