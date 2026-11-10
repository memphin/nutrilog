-- Vitalion schema v1 (Phase 0). Portable SQL: TEXT UUIDs, ISO-8601 TEXT timestamps,
-- INTEGER 0/1 booleans, REAL for quantities. Every user-data table carries the sync
-- columns created_at / updated_at / deleted_at / revision (see ADR-0003).

-- ---------------------------------------------------------------------------
-- Foods: custom, Open Food Facts products, USDA items, bundled items, recipes
-- ---------------------------------------------------------------------------
CREATE TABLE food (
    id              TEXT PRIMARY KEY,                 -- UUID
    name            TEXT NOT NULL,
    name_local      TEXT,                             -- e.g. Croatian name
    brand           TEXT,
    source          TEXT NOT NULL CHECK (source IN ('custom','off','usda','bundled','recipe')),
    source_id       TEXT,                             -- OFF barcode, USDA fdcId, bundled key
    -- Nutrients per 100 g (or per 100 ml for liquids)
    kcal_100        REAL NOT NULL,
    protein_g_100   REAL NOT NULL,
    carbs_g_100     REAL NOT NULL,
    fat_g_100       REAL NOT NULL,
    fiber_g_100     REAL,
    sugar_g_100     REAL,
    sat_fat_g_100   REAL,
    sodium_mg_100   REAL,
    micros_json     TEXT,                             -- reserved: {"vit_c_mg":..} (post-v1)
    is_liquid       INTEGER NOT NULL DEFAULT 0,       -- 1 → base unit ml
    default_serving_id TEXT,                          -- FK to serving.id (nullable, set after insert)
    image_url       TEXT,
    nutriscore      TEXT,                             -- 'a'..'e' from OFF
    data_quality    TEXT NOT NULL DEFAULT 'complete' CHECK (data_quality IN ('complete','partial_macros','energy_only')),
    is_favorite     INTEGER NOT NULL DEFAULT 0,
    use_count       INTEGER NOT NULL DEFAULT 0,
    last_used_at    TEXT,
    notes           TEXT,
    -- Recipe-only fields
    cooked_weight_g REAL,
    servings_count  REAL,
    -- Sync columns
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_food_source      ON food(source, source_id);
CREATE INDEX idx_food_last_used   ON food(last_used_at DESC);
CREATE INDEX idx_food_favorite    ON food(is_favorite) WHERE is_favorite = 1;
CREATE INDEX idx_food_updated     ON food(updated_at);

-- Full-text search over foods (SQLite-specific, mirrored by a tsvector column in Postgres).
CREATE VIRTUAL TABLE food_fts USING fts5(
    name, name_local, brand,
    content='food', content_rowid='rowid',
    tokenize = "unicode61 remove_diacritics 2"
);
CREATE TRIGGER food_ai AFTER INSERT ON food BEGIN
    INSERT INTO food_fts(rowid, name, name_local, brand) VALUES (new.rowid, new.name, new.name_local, new.brand);
END;
CREATE TRIGGER food_ad AFTER DELETE ON food BEGIN
    INSERT INTO food_fts(food_fts, rowid, name, name_local, brand) VALUES ('delete', old.rowid, old.name, old.name_local, old.brand);
END;
CREATE TRIGGER food_au AFTER UPDATE OF name, name_local, brand ON food BEGIN
    INSERT INTO food_fts(food_fts, rowid, name, name_local, brand) VALUES ('delete', old.rowid, old.name, old.name_local, old.brand);
    INSERT INTO food_fts(rowid, name, name_local, brand) VALUES (new.rowid, new.name, new.name_local, new.brand);
END;

-- A food can have several barcodes (multipacks, regional variants).
CREATE TABLE food_barcode (
    barcode         TEXT PRIMARY KEY,                 -- normalized EAN-13 / EAN-8 / UPC
    food_id         TEXT NOT NULL REFERENCES food(id) ON DELETE CASCADE,
    created_at      TEXT NOT NULL
);
CREATE INDEX idx_food_barcode_food ON food_barcode(food_id);

-- Serving definitions: "1 slice = 25 g", "1 cup = 240 ml"
CREATE TABLE serving (
    id              TEXT PRIMARY KEY,
    food_id         TEXT NOT NULL REFERENCES food(id) ON DELETE CASCADE,
    label           TEXT NOT NULL,
    grams           REAL NOT NULL CHECK (grams > 0),  -- grams or ml depending on food.is_liquid
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_serving_food ON serving(food_id);

-- Recipe ingredients (food.source = 'recipe'). Snapshot keeps the recipe stable if the ingredient food changes.
CREATE TABLE recipe_ingredient (
    id              TEXT PRIMARY KEY,
    recipe_id       TEXT NOT NULL REFERENCES food(id) ON DELETE CASCADE,
    food_id         TEXT REFERENCES food(id) ON DELETE SET NULL,
    display_name    TEXT NOT NULL,
    grams           REAL NOT NULL CHECK (grams > 0),
    kcal_100        REAL NOT NULL,
    protein_g_100   REAL NOT NULL,
    carbs_g_100     REAL NOT NULL,
    fat_g_100       REAL NOT NULL,
    fiber_g_100     REAL,
    sugar_g_100     REAL,
    sat_fat_g_100   REAL,
    sodium_mg_100   REAL,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_recipe_ingredient_recipe ON recipe_ingredient(recipe_id);

-- Saved meals ("my usual breakfast")
CREATE TABLE meal_template (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    meal_slot_hint  TEXT,
    use_count       INTEGER NOT NULL DEFAULT 0,
    last_used_at    TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE meal_template_item (
    id              TEXT PRIMARY KEY,
    template_id     TEXT NOT NULL REFERENCES meal_template(id) ON DELETE CASCADE,
    food_id         TEXT NOT NULL REFERENCES food(id) ON DELETE CASCADE,
    grams           REAL NOT NULL CHECK (grams > 0),
    serving_id      TEXT REFERENCES serving(id) ON DELETE SET NULL,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_meal_template_item_template ON meal_template_item(template_id);

-- ---------------------------------------------------------------------------
-- Diary
-- ---------------------------------------------------------------------------
CREATE TABLE meal_slot (
    id              TEXT PRIMARY KEY,                 -- 'breakfast','lunch','dinner','snacks' or custom UUID
    name            TEXT NOT NULL,
    sort_order      INTEGER NOT NULL,
    default_start_hour INTEGER,                       -- used to preselect slot when logging
    is_active       INTEGER NOT NULL DEFAULT 1,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE diary_entry (
    id              TEXT PRIMARY KEY,
    day             TEXT NOT NULL,                    -- 'YYYY-MM-DD' in the user's local calendar
    meal_slot_id    TEXT NOT NULL REFERENCES meal_slot(id),
    food_id         TEXT REFERENCES food(id) ON DELETE SET NULL,  -- NULL for quick-add
    display_name    TEXT NOT NULL,                    -- food name at log time (survives food deletion)
    grams           REAL NOT NULL CHECK (grams >= 0),
    serving_label   TEXT,                             -- e.g. "2 slices"
    is_quick_add    INTEGER NOT NULL DEFAULT 0,
    -- Nutrient snapshot = totals for this entry at log time (source of truth for history)
    kcal            REAL NOT NULL,
    protein_g       REAL NOT NULL,
    carbs_g         REAL NOT NULL,
    fat_g           REAL NOT NULL,
    fiber_g         REAL,
    sugar_g         REAL,
    sat_fat_g       REAL,
    sodium_mg       REAL,
    note            TEXT,
    logged_at       TEXT NOT NULL,                    -- actual timestamp of the entry
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_diary_entry_day      ON diary_entry(day, meal_slot_id, sort_order);
CREATE INDEX idx_diary_entry_food     ON diary_entry(food_id);
CREATE INDEX idx_diary_entry_updated  ON diary_entry(updated_at);

-- HealthKit samples written for an entry (several per entry: energy, protein, ...)
CREATE TABLE healthkit_link (
    id              TEXT PRIMARY KEY,
    owner_table     TEXT NOT NULL CHECK (owner_table IN ('diary_entry','water_entry','weight_entry')),
    owner_id        TEXT NOT NULL,
    hk_type         TEXT NOT NULL,                    -- e.g. 'HKQuantityTypeIdentifierDietaryEnergyConsumed'
    hk_uuid         TEXT NOT NULL,                    -- HKObject.uuid
    created_at      TEXT NOT NULL
);
CREATE INDEX idx_healthkit_link_owner ON healthkit_link(owner_table, owner_id);
CREATE UNIQUE INDEX idx_healthkit_link_uuid ON healthkit_link(hk_uuid);

CREATE TABLE day_note (
    day             TEXT PRIMARY KEY,
    text            TEXT NOT NULL,
    is_complete     INTEGER NOT NULL DEFAULT 0,       -- user marked "day fully logged" (used by TDEE)
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);

-- ---------------------------------------------------------------------------
-- Body & activity
-- ---------------------------------------------------------------------------
CREATE TABLE water_entry (
    id              TEXT PRIMARY KEY,
    day             TEXT NOT NULL,
    logged_at       TEXT NOT NULL,
    ml              REAL NOT NULL CHECK (ml > 0),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_water_entry_day ON water_entry(day);

-- Manual weight entries made in-app (Health-sourced weights live in daily_metrics / Health itself)
CREATE TABLE weight_entry (
    id              TEXT PRIMARY KEY,
    measured_at     TEXT NOT NULL,
    kg              REAL NOT NULL CHECK (kg > 0),
    body_fat_pct    REAL,
    source          TEXT NOT NULL DEFAULT 'manual',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_weight_entry_measured ON weight_entry(measured_at);

-- Cache of Apple Health per day. Health is the system of record; this table can be truncated and rebuilt.
CREATE TABLE daily_metrics (
    day             TEXT PRIMARY KEY,
    steps           INTEGER,
    active_kcal     REAL,
    basal_kcal      REAL,
    sleep_asleep_min INTEGER,
    sleep_in_bed_min INTEGER,
    sleep_core_min  INTEGER,
    sleep_deep_min  INTEGER,
    sleep_rem_min   INTEGER,
    sleep_awake_min INTEGER,
    weight_kg       REAL,                             -- first measurement of the day
    body_fat_pct    REAL,
    weight_trend_kg REAL,                             -- EMA, computed by Core
    resting_hr      REAL,
    hrv_sdnn_ms     REAL,                             -- overnight average
    water_ml        REAL,                             -- includes water from other Health apps
    source_summary  TEXT,                             -- JSON: {"steps":"Apple Watch","weight":"Withings"}
    fetched_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    revision        INTEGER NOT NULL DEFAULT 1
);

-- ---------------------------------------------------------------------------
-- Profile, targets, TDEE
-- ---------------------------------------------------------------------------
CREATE TABLE profile (
    id              INTEGER PRIMARY KEY CHECK (id = 1), -- single row
    height_cm       REAL,
    birth_date      TEXT,
    sex             TEXT CHECK (sex IN ('male','female','other')),
    activity_level  TEXT NOT NULL DEFAULT 'light' CHECK (activity_level IN ('sedentary','light','moderate','active','very_active')),
    goal_mode       TEXT NOT NULL DEFAULT 'maintain' CHECK (goal_mode IN ('lose','maintain','gain')),
    goal_rate_kg_per_week REAL NOT NULL DEFAULT 0,
    water_goal_ml   REAL NOT NULL DEFAULT 2500,
    checkin_weekday INTEGER NOT NULL DEFAULT 2,        -- 1=Sunday … 7=Saturday (Calendar.weekday); 2 = Monday
    updated_at      TEXT NOT NULL,
    revision        INTEGER NOT NULL DEFAULT 1
);

-- Targets are versioned: a new row becomes effective from a given day; history stays intact.
CREATE TABLE target (
    id              TEXT PRIMARY KEY,
    effective_from  TEXT NOT NULL,                    -- 'YYYY-MM-DD'
    kcal            REAL NOT NULL,
    protein_g       REAL NOT NULL,
    carbs_g         REAL NOT NULL,
    fat_g           REAL NOT NULL,
    fiber_g         REAL,
    weekday_overrides_json TEXT,                      -- {"2":{"kcal":2400,...}} per Calendar.weekday
    origin          TEXT NOT NULL CHECK (origin IN ('manual','formula','adaptive')),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_target_effective ON target(effective_from DESC);

-- Weekly adaptive TDEE check-ins (SPEC §5.4.1)
CREATE TABLE tdee_estimate (
    id              TEXT PRIMARY KEY,
    computed_for_day TEXT NOT NULL,                   -- the check-in day
    window_days     INTEGER NOT NULL,
    logged_days     INTEGER NOT NULL,
    mean_intake_kcal REAL NOT NULL,
    trend_start_kg  REAL NOT NULL,
    trend_end_kg    REAL NOT NULL,
    tdee_kcal       REAL NOT NULL,
    confidence      TEXT NOT NULL CHECK (confidence IN ('low','medium','high')),
    proposed_target_kcal REAL,
    decision        TEXT CHECK (decision IN ('accepted','edited','skipped')),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_tdee_estimate_day ON tdee_estimate(computed_for_day DESC);

-- ---------------------------------------------------------------------------
-- Caches & settings
-- ---------------------------------------------------------------------------
CREATE TABLE off_product_cache (
    barcode         TEXT PRIMARY KEY,
    json            TEXT NOT NULL,                    -- raw OFF response (fields allowlist)
    last_modified_t INTEGER,
    fetched_at      TEXT NOT NULL
);

CREATE TABLE setting (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL,                    -- JSON-encoded
    updated_at      TEXT NOT NULL
);

-- Default meal slots
INSERT INTO meal_slot (id, name, sort_order, default_start_hour, is_active, created_at, updated_at) VALUES
 ('breakfast','Breakfast',0, 5,1,strftime('%Y-%m-%dT%H:%M:%fZ','now'),strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 ('lunch',    'Lunch',    1,11,1,strftime('%Y-%m-%dT%H:%M:%fZ','now'),strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 ('dinner',   'Dinner',   2,17,1,strftime('%Y-%m-%dT%H:%M:%fZ','now'),strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 ('snacks',   'Snacks',   3,NULL,1,strftime('%Y-%m-%dT%H:%M:%fZ','now'),strftime('%Y-%m-%dT%H:%M:%fZ','now'));

INSERT INTO profile (id, updated_at) VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
