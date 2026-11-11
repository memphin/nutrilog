-- Caffeine tracking: how much caffeine is in the body now and when it falls below a "sleep safe" line.
-- Caffeine comes from quick-add drinks (`caffeine_entry`) and from diary entries of foods that state it.

-- Optional caffeine like the other optional nutrients: per 100 g/ml on foods, the logged amount's total on
-- diary entries (snapshot at log time; consumption time is `diary_entry.logged_at`).
ALTER TABLE food ADD COLUMN caffeine_mg_100 REAL;
ALTER TABLE diary_entry ADD COLUMN caffeine_mg REAL;

-- Quick-add caffeine drinks logged in Vitalion (espresso, tea, …), like `water_entry`. Not written to Apple Health.
CREATE TABLE caffeine_entry (
    id              TEXT PRIMARY KEY,
    day             TEXT NOT NULL,                    -- 'YYYY-MM-DD' in the user's local calendar
    logged_at       TEXT NOT NULL,                    -- when it was drunk
    mg              REAL NOT NULL CHECK (mg > 0),
    drink_id        TEXT,                             -- preset id (Core `CaffeineDrink.id`), NULL for a custom amount
    name            TEXT,                             -- display name at log time
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_caffeine_entry_day ON caffeine_entry(day);

-- Diary entries with caffeine, for the dashboard's caffeine curve (few rows match, so a partial index stays small).
CREATE INDEX idx_diary_entry_caffeine ON diary_entry(day) WHERE caffeine_mg > 0 AND deleted_at IS NULL;
