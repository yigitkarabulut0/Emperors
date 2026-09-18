-- +goose Up
-- +goose StatementBegin

-- One row per scheduled job: which period it last claimed, and how that went.
--
-- The server had two hand-written loops (reputation decay, leaderboards), each
-- with its own idea of "once". Everything ahead -- hourly events, weekly boards,
-- season settlement, the push sender -- needs the same thing: run once per
-- period, across restarts and replicas, and never twice. A claim row does that
-- with one statement: the job runs only when its row names an earlier period
-- (or a claim whose lease has run out, from a process that died mid-run).
--
-- A row rather than a session advisory lock: Neon's pooler hands out a different
-- connection per transaction, and a session lock cannot be held across one.
CREATE TABLE app.job_runs (
    job_name    text        PRIMARY KEY,
    period_key  text        NOT NULL,
    claimed_at  timestamptz NOT NULL,
    claimed_by  text        NOT NULL,
    finished_at timestamptz,
    last_ok_at  timestamptz,
    last_error  text,
    run_count   bigint      NOT NULL DEFAULT 0,
    fail_count  bigint      NOT NULL DEFAULT 0
);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.job_runs;
