-- Bookkeeping for the janitorial sweeps (worker/src/sweep.ts): currently the
-- resumable R2 list cursor for the orphan-blob sweep. Generic k/v so future
-- sweeps don't each need a table.
CREATE TABLE IF NOT EXISTS sweep_state (
    k          TEXT PRIMARY KEY,
    v          TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
