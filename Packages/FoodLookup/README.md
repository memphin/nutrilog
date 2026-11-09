# FoodLookup

Glue between the online food sources and the local database. A package of its own so that Persistence and
FoodSources stay independent of each other (it depends on Core, Persistence and FoodSources).

- `BarcodeLookup`: the barcode pipeline (SPEC §9, FR-11). Local `food_barcode` → `off_product_cache` →
  Open Food Facts → cache the answer. Returns `.local(FoodDetail)`, `.remote(RemoteProduct)` or `.notFound`;
  throws `BarcodeLookupError.offline` / `.unavailable` when OFF can't be reached and nothing usable is cached.
  - Cache policy (`BarcodeLookup.CachePolicy.standard`): products are fresh for 30 days, "not found" answers for
    7 days, and entries older than 90 days are evicted (`BarcodeLookup.evictExpiredCache(in:)`, run at app launch).
  - When OFF can't be reached, an expired cached product is returned (`RemoteProduct.origin == .staleCache`).
  - Ambiguous 8-digit codes: every candidate key (`Barcode.candidates`, `ScannedBarcode.candidates`) is tried in
    order at each step.
- `FoodDetail(draft:)` and `FoodRepository.saveRemoteCopy(_:)`: store a local copy of an online `FoodDraft`
  (barcode scan or online search) before logging it. Idempotent by barcode and by source + source ID.
  A per-serving-only draft (no usable serving weight) becomes a food with `perServingOnly` set and a 100 g/ml
  stand-in serving; `FoodDetail.isPerServingPlaceholder` tells the UI to log it by servings only.
- `FoodDetail.convertingPerServingPlaceholder(servingWeight:missing:)`: the one conversion used by the scan flow
  and online search once the serving weight is known — values to per 100, real serving weight, only the automatic
  per-serving note cleared, quality from the stored food (complete when nothing is missing), and a plausibility
  guard (`ServingWeightError`: ≤ 900 kcal and ≤ 105 g protein + carbs + fat per 100).

Run tests: `cd Packages/FoodLookup && swift test`
