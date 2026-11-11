-- Hydration: everything drunk counts towards the day's fluid, not only water. Each drink's volume is snapshotted at
-- log time (like the nutrients), so changing a food or a preset later doesn't rewrite history.

-- Fluid of a diary entry in ml; NULL = not a drink (solid foods, quick-adds). Set at log time from the food
-- (Core `FluidRule`): liquid foods with at most 50 g fat per 100 ml, or any food the user marked as a drink.
ALTER TABLE diary_entry ADD COLUMN fluid_ml REAL;
-- Per-food override of the automatic rule: NULL automatic, 1 always counts as a drink, 0 never.
ALTER TABLE food ADD COLUMN counts_as_fluid INTEGER;
-- Volume of a caffeine quick-add in ml: the preset's serving at log time, optional for a custom amount.
ALTER TABLE caffeine_entry ADD COLUMN ml REAL;
-- When the user woke up (end of the night's last asleep sample before noon), from Apple Health; NULL when unknown.
ALTER TABLE daily_metrics ADD COLUMN woke_at TEXT;
-- How the daily goal is set: 'weight' (30 ml per kg of trend weight) or 'fixed' (`water_goal_ml`).
ALTER TABLE profile ADD COLUMN water_goal_mode TEXT NOT NULL DEFAULT 'weight' CHECK (water_goal_mode IN ('weight','fixed'));

-- The backfills of existing diary entries and the goal mode run after this file, in Swift (`HydrationBackfill`), so
-- importing an older export can run them again.

-- Diary entries that are drinks, for the hydration timeline (few rows match, so a partial index stays small).
CREATE INDEX idx_diary_entry_fluid ON diary_entry(day) WHERE fluid_ml > 0 AND deleted_at IS NULL;
