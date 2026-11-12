-- Training days: on a training day the calorie target (as extra carbs) and the hydration goal are raised by a boost.
-- Like `target`, the default weekdays and boost are history: a schedule row is in effect from its `effective_from` until
-- the next one, so changing the defaults never rewrites past days. A day the user switched on or off is a
-- `training_day` row, which ignores the weekdays. No schedule row = no training weekdays and the default boost (10 %).

CREATE TABLE training_schedule (
    id              TEXT PRIMARY KEY,
    effective_from  TEXT NOT NULL,                    -- 'YYYY-MM-DD'
    weekdays_json   TEXT NOT NULL DEFAULT '[]',       -- sorted Calendar.weekday numbers, 1=Sunday … 7=Saturday, e.g. [2,4,6]
    boost_percent   INTEGER NOT NULL DEFAULT 10 CHECK (boost_percent >= 0),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
-- One live schedule per first day (a new schedule on the same day replaces it).
CREATE UNIQUE INDEX idx_training_schedule_effective ON training_schedule(effective_from) WHERE deleted_at IS NULL;

-- Days the user switched on or off by hand; a cleared override is a tombstone (`deleted_at`).
CREATE TABLE training_day (
    day             TEXT PRIMARY KEY,                 -- 'YYYY-MM-DD' in the user's local calendar
    is_training     INTEGER NOT NULL CHECK (is_training IN (0,1)),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT,
    revision        INTEGER NOT NULL DEFAULT 1
);
