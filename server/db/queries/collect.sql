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

-- Applies one collect: spends energy, credits gold and XP, and advances the
-- action sequence. Energy is written back already settled by the caller.
-- name: ApplyCollect :one
UPDATE app.players
SET energy_milli      = $2,
    energy_updated_at = $3,
    gold              = gold + $4,
    xp                = $5,
    level             = $6,
    stat_points_unspent = stat_points_unspent + $7,
    action_seq        = $8,
    last_seen_at      = now()
WHERE id = $1
RETURNING *;

-- name: SettleEnergy :exec
UPDATE app.players SET energy_milli = $2, energy_updated_at = $3 WHERE id = $1;
