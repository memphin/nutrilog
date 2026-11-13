-- Workouts read from Apple Health, one row each (the Training tab). Like `daily_metrics` a copy of Health, which stays
-- the system of record — but kept beyond the days a sync reads, because a workout that counts as training makes its
-- day a training day (FR-32) and past days keep their status. A workout deleted in Health is a tombstone (`deleted_at`).

CREATE TABLE health_workout (
    id                  TEXT PRIMARY KEY,             -- HKWorkout UUID, lowercase
    day                 TEXT NOT NULL,                -- 'YYYY-MM-DD' the workout started on, in the user's local calendar
    activity_type       INTEGER NOT NULL,             -- HKWorkoutActivityType raw value, e.g. 50 = strength training
    start_at            TEXT NOT NULL,
    end_at              TEXT NOT NULL,
    duration_sec        REAL NOT NULL CHECK (duration_sec >= 0), -- without pauses
    active_kcal         REAL,
    distance_m          REAL,
    source_name         TEXT NOT NULL DEFAULT '',     -- e.g. "Ivan's Apple Watch"
    source_bundle_id    TEXT NOT NULL DEFAULT '',
    source_product_type TEXT,                         -- e.g. "Watch7,1"
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    deleted_at          TEXT,
    revision            INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_health_workout_day ON health_workout(day);
CREATE INDEX idx_health_workout_start ON health_workout(start_at);
