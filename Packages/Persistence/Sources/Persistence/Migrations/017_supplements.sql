-- Supplements and medications the user takes, and the doses taken or skipped. A supplement has fixed times of day
-- (every day or on some weekdays) or none (taken as needed). A scheduled dose that has no live `supplement_dose`
-- row is open; reminders are local notifications planned from these tables, not stored.

CREATE TABLE supplement (
    id                  TEXT PRIMARY KEY,
    name                TEXT NOT NULL CHECK (length(trim(name)) > 0),
    dose                TEXT NOT NULL DEFAULT '',         -- free text, e.g. '1 tablet', '500 mg'
    note                TEXT,                             -- e.g. 'with food'
    times_json          TEXT NOT NULL DEFAULT '[]',       -- sorted minutes after midnight, e.g. [480,1260]; [] = as needed
    weekdays_json       TEXT NOT NULL DEFAULT '[]',       -- Calendar.weekday numbers 1=Sunday … 7=Saturday; [] = every day
    start_day           TEXT NOT NULL,                    -- 'YYYY-MM-DD': no doses are due before it
    reminders_enabled   INTEGER NOT NULL DEFAULT 1 CHECK (reminders_enabled IN (0,1)),
    is_active           INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    sort_order          INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    deleted_at          TEXT,
    revision            INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE supplement_dose (
    id                  TEXT PRIMARY KEY,
    supplement_id       TEXT NOT NULL REFERENCES supplement(id),
    day                 TEXT NOT NULL,                    -- 'YYYY-MM-DD' in the user's local calendar
    scheduled_minute    INTEGER CHECK (scheduled_minute BETWEEN 0 AND 1439), -- the scheduled time; NULL = an extra dose
    status              TEXT NOT NULL CHECK (status IN ('taken','skipped')),
    taken_at            TEXT,                             -- when it was taken; NULL when skipped
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    deleted_at          TEXT,
    revision            INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_supplement_dose_day ON supplement_dose(day);
-- One live row per scheduled dose; extra doses can repeat.
CREATE UNIQUE INDEX idx_supplement_dose_scheduled ON supplement_dose(supplement_id, day, scheduled_minute)
    WHERE deleted_at IS NULL AND scheduled_minute IS NOT NULL;
