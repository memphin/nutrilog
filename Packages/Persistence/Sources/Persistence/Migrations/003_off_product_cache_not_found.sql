-- Barcode lookup cache (backlog #19, SPEC §9). Rebuilt so it can also remember "Open Food Facts has no such
-- product" (a negative cache with a shorter lifetime), so repeated scans of an unknown code don't query OFF each time.
-- Nothing wrote to the v1 table and it only holds re-fetchable data, so it is dropped rather than migrated.
-- Like daily_metrics it is a cache, not user data: no sync columns, never exported (see DataPortability.tables).
DROP TABLE off_product_cache;
CREATE TABLE off_product_cache (
    barcode         TEXT PRIMARY KEY,                 -- normalized key the product was looked up under
    status          TEXT NOT NULL CHECK (status IN ('found','not_found')),
    json            TEXT,                             -- OFF product (fields allowlist) as JSON; NULL when not_found
    last_modified_t INTEGER,                          -- OFF last_modified_t, Unix seconds
    fetched_at      TEXT NOT NULL,                    -- when OFF answered; drives freshness and eviction
    CHECK ((status = 'found') = (json IS NOT NULL))
);
CREATE INDEX idx_off_product_cache_fetched ON off_product_cache(fetched_at);
