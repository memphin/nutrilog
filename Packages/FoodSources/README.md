# FoodSources

Open Food Facts client, USDA FDC client, bundled food index, barcode lookup pipeline.

- `OpenFoodFactsClient` (protocol) / `OpenFoodFactsHTTPClient`: OFF v2 product lookup by barcode — fields
  allowlist, `User-Agent` from Info.plist `OFFUserAgentContact`, 8 s timeout, 2 retries with backoff,
  `OpenFoodFactsError` (`.notFound` for `status: 0`, `.offline`, …).
- `OpenFoodFactsSearchClient` (protocol) / `OpenFoodFactsSearchHTTPClient`: OFF v1 full-text search
  (`/cgi/search.pl?search_terms=…&search_simple=1&json=1`, same fields allowlist and `User-Agent`), 5 s timeout and
  no retries (interactive typing), never cached in `URLCache`; hits without a code or any nutrition are dropped.
  `OFFSearchThrottle` spaces requests ≥ 1.5 s apart; HTTP 429/503 (OFF's throttle page) → `.rateLimited` and a
  60 s cool-down (`rateLimitedUntil`) with no requests.
- `FoodNameCasing` / `FoodDraft.displayCased`: title-cases ALL CAPS names and brands (USDA Branded).
- `OFFFoodMapper`: `OFFProduct` → `FoodDraft` (kcal/kJ, salt → sodium, per-serving scaling, data quality).
- `USDAClient` (protocol) / `USDAHTTPClient`: FDC `/v1/foods/search` over Foundation, SR Legacy and Branded,
  optional API key (sent in the `X-Api-Key` header, never in a URL, never in a description or `dump`). Without a
  key `isAvailable` is false and `search` throws `.missingAPIKey` without a request. HTTP 429 starts a one-hour
  in-memory cool-down (`rateLimitedUntil`, `USDAError.rateLimited(until:)`); 5xx/dropped connections are retried
  like OFF.
- `FDCFoodMapper`: `FDCFood` → `FoodDraft` (`origin = .usda`, `sourceID` = FDC ID) by nutrient ID — energy 1008,
  else 1062 kJ, else Atwater 2048/2047; protein 1003; fat 1004/1085; carbs 1005/1050; fiber 1079/2033; sugars
  2000/1063; saturated fat 1258; sodium 1093 — with kcal/kJ and g/mg/µg conversion.
- `FoodDraft`: neutral, unsaved food; the app converts it to `Persistence.Food` (FoodSources doesn't depend on
  Persistence).
- Shared by both clients: `HTTPTransport` (network seam), `HTTPRetryPolicy`, lenient JSON decoding,
  `NutrientValues` (plausibility rules), `MeasureParser`.
- Tests use JSON fixtures in `Tests/FoodSourcesTests/Fixtures/OFF` and `Fixtures/USDA` (trimmed real FDC
  responses captured with `DEMO_KEY`, plus hand-built edge cases in `search_edge_cases.json`).

Run tests: `cd Packages/FoodSources && swift test`
