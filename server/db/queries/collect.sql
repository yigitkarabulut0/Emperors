-- name: GetJobProgress :one
SELECT * FROM app.player_job_progress WHERE player_id = $1 AND job_id = $2;

-- name: ListJobProgress :many
SELECT * FROM app.player_job_progress WHERE player_id = $1;

-- name: BumpJobProgress :one
INSERT INTO app.player_job_progress (player_id, job_id, collects)
VALUES ($1, $2, 1)
ON CONFLICT (player_id, job_id)
DO UPDATE SET collects = app.player_job_progress.collects + 1
RETURNING *;

-- Advances a job's lifetime count by several collects at once.
--
-- A burst of taps on one job is the single most common thing that happens in
-- this game, and doing it a row at a time meant one database round trip per tap
-- inside the transaction. The mastery bonus still has to be computed per collect
-- -- it depends on the count BEFORE each one -- but that is arithmetic the
-- caller can do in a loop from the returned total.
-- name: BumpJobProgressBy :one
INSERT INTO app.player_job_progress (player_id, job_id, collects)
VALUES ($1, $2, sqlc.arg(n)::bigint)
ON CONFLICT (player_id, job_id)
DO UPDATE SET collects = app.player_job_progress.collects + sqlc.arg(n)::bigint
RETURNING *;

-- Applies one collect: spends energy, credits gold and XP, and advances the
-- action sequence. Energy is written back already settled by the caller.
--
-- The level-up diamonds repay any refund debt before they reach the purse (see
-- CreditDiamonds); with nothing owed the two lines reduce to "+ diamonds".
-- name: ApplyCollect :one
UPDATE app.players
SET energy_milli        = sqlc.arg(energy_milli),
    energy_updated_at   = sqlc.arg(energy_updated_at),
    gold                = gold + sqlc.arg(gold)::bigint,
    xp                  = sqlc.arg(xp),
    level               = sqlc.arg(level),
    stat_points_unspent = stat_points_unspent + sqlc.arg(stat_points_unspent)::int,
    diamonds            = diamonds + GREATEST(0, sqlc.arg(diamonds)::bigint - diamond_debt),
    diamond_debt        = GREATEST(0, diamond_debt - sqlc.arg(diamonds)::bigint),
    action_seq          = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: SettleEnergy :exec
UPDATE app.players SET energy_milli = $2, energy_updated_at = $3 WHERE id = $1;
