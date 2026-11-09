-- Rows whose Apple Health copy must be (re)written or deleted (backlog #27). Repositories add a row in the same
-- transaction as the change, so a crash or a failed Health write never loses the work: the app's writer drains
-- the queue after the commit and keeps failed rows (attempts, last_error) for the next try.
-- Device-local bookkeeping like healthkit_link: no sync columns, not exported.
CREATE TABLE healthkit_outbox (
    owner_table     TEXT NOT NULL CHECK (owner_table IN ('diary_entry','water_entry','weight_entry')),
    owner_id        TEXT NOT NULL,
    generation      INTEGER NOT NULL,                 -- from healthkit_outbox_sequence; new on every (re)queue
    attempts        INTEGER NOT NULL DEFAULT 0,       -- attempts started since the last queueing
    last_error      TEXT,
    queued_at       TEXT NOT NULL,
    PRIMARY KEY (owner_table, owner_id)
);

-- Monotonic generation counter: never reused, even after the queue was emptied, so a writer finishing an old
-- generation can never remove a row that was queued again meanwhile.
CREATE TABLE healthkit_outbox_sequence (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    value           INTEGER NOT NULL
);
INSERT INTO healthkit_outbox_sequence (id, value) VALUES (1, 0);
