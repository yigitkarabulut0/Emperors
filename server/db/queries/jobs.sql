-- The scheduled-job claim table. See migration 00029.

-- Claims a job for a period. A row comes back only to the one caller that should
-- run it: when the stored period is a different one, or when a claim on this
-- period was never finished and its lease has run out (the process that took it
-- died). Zero rows means "not yours, not now".
-- name: ClaimJob :one
INSERT INTO app.job_runs (job_name, period_key, claimed_at, claimed_by)
VALUES (sqlc.arg(job_name), sqlc.arg(period_key), now(), sqlc.arg(claimed_by))
ON CONFLICT (job_name) DO UPDATE
SET period_key  = EXCLUDED.period_key,
    claimed_at  = now(),
    claimed_by  = EXCLUDED.claimed_by,
    finished_at = NULL
WHERE app.job_runs.period_key IS DISTINCT FROM EXCLUDED.period_key
   OR (app.job_runs.finished_at IS NULL
       AND app.job_runs.claimed_at < now() - make_interval(secs => sqlc.arg(lease_seconds)::int))
RETURNING *;

-- A run that succeeded.
-- name: FinishJobOK :exec
UPDATE app.job_runs
SET finished_at = now(), last_ok_at = now(), last_error = NULL, run_count = run_count + 1
WHERE job_name = sqlc.arg(job_name);

-- A run that failed. With retry the period is cleared, so the next tick claims
-- it again; without, the period stays claimed and the failure is final.
-- name: FinishJobFailed :exec
UPDATE app.job_runs
SET finished_at = now(),
    last_error  = sqlc.arg(last_error),
    fail_count  = fail_count + 1,
    period_key  = CASE WHEN sqlc.arg(retry)::boolean THEN '' ELSE period_key END
WHERE job_name = sqlc.arg(job_name);

-- Every job and its last run, for the admin panel.
-- name: ListJobRuns :many
SELECT * FROM app.job_runs ORDER BY job_name;
