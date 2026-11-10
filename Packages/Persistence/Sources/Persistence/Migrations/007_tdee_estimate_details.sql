-- Weekly check-in details (backlog #35, SPEC §5.4.1 steps 5–7). The v1 table holds the headline numbers; these
-- columns keep what the history screen and its "how was this computed" sheet show for past check-ins.
ALTER TABLE tdee_estimate ADD COLUMN raw_tdee_kcal REAL;          -- estimate before blending and clamping
ALTER TABLE tdee_estimate ADD COLUMN baseline_kcal REAL;          -- Mifflin-St Jeor × activity at the time
ALTER TABLE tdee_estimate ADD COLUMN weekly_change_kg REAL;       -- actual trend change per week (negative = loss)
ALTER TABLE tdee_estimate ADD COLUMN goal_change_kg_per_week REAL; -- signed goal rate at the time
ALTER TABLE tdee_estimate ADD COLUMN previous_target_kcal REAL;   -- calorie target before the check-in
ALTER TABLE tdee_estimate ADD COLUMN applied_target_kcal REAL;    -- target written by 'accepted' / 'edited'
ALTER TABLE tdee_estimate ADD COLUMN details_json TEXT;           -- the full estimate incl. the days used (JSON)
