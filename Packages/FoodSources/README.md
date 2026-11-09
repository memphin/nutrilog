# FoodSources

Open Food Facts client, USDA FDC client, bundled food index, barcode lookup pipeline.

- `OpenFoodFactsClient` (protocol) / `OpenFoodFactsHTTPClient`: OFF v2 product lookup by barcode — fields
  allowlist, `User-Agent` from Info.plist `OFFUserAgentContact`, 8 s timeout, 2 retries with backoff,
  `OpenFoodFactsError` (`.notFound` for `status: 0`, `.offline`, …).
- `OFFFoodMapper`: `OFFProduct` → `FoodDraft` (kcal/kJ, salt → sodium, per-serving scaling, data quality).
- `FoodDraft`: neutral, unsaved food; the app converts it to `Persistence.Food` (FoodSources doesn't depend on
  Persistence).
- `HTTPTransport`: network seam; tests use the OFF JSON fixtures in `Tests/FoodSourcesTests/Fixtures/OFF`.

Run tests: `cd Packages/FoodSources && swift test`
