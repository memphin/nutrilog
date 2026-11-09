-- Rows whose Apple Health copy must be (re)written or deleted (backlog #27). Repositories add a row in the same
-- transaction as the change, so a crash or a failed Health write never loses the work: the app's writer drains
-- the queue after the commit and keeps failed rows (attempts, last_error) for the next try.
-- Device-local bookkeeping like healthkit_link: no sync columns, not exported.
CREATE TABLE healthkit_outbox (
    owner_table     TEXT NOT NULL CHECK (owner_table IN ('diary_entry','water_entry','weight_entry')),
    owner_id        TEXT NOT NULL,
    generation      INTEGER NOT NULL,                 -- larger than every other row's on each (re)queue
    attempts        INTEGER NOT NULL DEFAULT 0,       -- failed attempts since the last queueing
    last_error      TEXT,
    queued_at       TEXT NOT NULL,
    PRIMARY KEY (owner_table, owner_id)
);
