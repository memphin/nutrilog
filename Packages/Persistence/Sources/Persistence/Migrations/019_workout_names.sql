-- Workouts started from a custom workout on Apple Watch (refereeing), and names the user gives workouts.

-- 1 when one of the workout's steps is in its metadata (`WOIntervalStepKeyPath`): a custom workout. Rows read before
-- this are 0 until the next full sync reads them again.
ALTER TABLE health_workout ADD COLUMN is_custom INTEGER NOT NULL DEFAULT 0;

-- A name the user gave a workout in Vitalion, shown instead of the kind's. Kept apart from `health_workout`, which a
-- sync rewrites from Health. Clearing the name deletes the row (a tombstone).
CREATE TABLE workout_name (
    workout_id  TEXT PRIMARY KEY,                     -- health_workout.id (HKWorkout UUID, lowercase)
    name        TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    deleted_at  TEXT,
    revision    INTEGER NOT NULL DEFAULT 1
);
