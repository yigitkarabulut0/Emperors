-- name: CreatePlayer :one
INSERT INTO app.players (username, display_name, energy_milli, reset_offset_minutes)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetPlayerByID :one
SELECT * FROM app.players WHERE id = $1;

-- name: GetPlayerByUsername :one
SELECT * FROM app.players WHERE lower(username) = lower($1);

-- Locks the row for the duration of the transaction. Every mutating action
-- takes this first, so two concurrent collects cannot both read the same energy
-- and both spend it.
-- name: LockPlayer :one
SELECT * FROM app.players WHERE id = $1 FOR UPDATE;

-- name: TouchPlayerSeen :exec
UPDATE app.players SET last_seen_at = now() WHERE id = $1;
