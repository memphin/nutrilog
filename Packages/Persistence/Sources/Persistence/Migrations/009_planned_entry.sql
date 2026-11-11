-- Meal plan (meal prep): foods planned for a day and slot, confirmed into the diary when eaten.
-- Kept apart from `diary_entry` so a plan never counts as eaten: it is not in day totals, the TDEE estimate,
-- Apple Health or the CSV export until it is confirmed, which logs a real diary entry.
CREATE TABLE planned_entry (
    id              TEXT PRIMARY KEY,
    day             TEXT NOT NULL,                    -- 'YYYY-MM-DD' in the user's local calendar
    meal_slot_id    TEXT NOT NULL REFERENCES meal_slot(id),
    food_id         TEXT REFERENCES food(id) ON DELETE SET NULL,  -- NULL for quick-add
    display_name    TEXT NOT NULL,
    grams           REAL NOT NULL CHECK (grams >= 0),
    serving_label   TEXT,
    is_quick_add    INTEGER NOT NULL DEFAULT 0,
    -- Nutrient estimate for planning; refreshed from the food's current values when the plan is confirmed.
    kcal            REAL NOT NULL,
    protein_g       REAL NOT NULL,
    carbs_g         REAL NOT NULL,
    fat_g           REAL NOT NULL,
    fiber_g         REAL,
    sugar_g         REAL,
    sat_fat_g       REAL,
    sodium_mg       REAL,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    -- The diary entry logged when confirmed. While that entry is active the plan counts as eaten; deleting the
    -- entry (or undoing the confirmation) makes the plan pending again.
    eaten_entry_id  TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_planned_entry_day     ON planned_entry(day, meal_slot_id, sort_order);
CREATE INDEX idx_planned_entry_food    ON planned_entry(food_id);
CREATE INDEX idx_planned_entry_updated ON planned_entry(updated_at);
