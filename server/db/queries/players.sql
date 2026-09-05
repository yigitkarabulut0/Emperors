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

-- Spends level-up points. The WHERE clause carries the affordability check, so
-- the balance cannot go negative even under a concurrent double-tap.
-- name: SpendStatPoints :one
UPDATE app.players
SET stat_energy  = stat_energy  + $2,
    stat_attack  = stat_attack  + $3,
    stat_defense = stat_defense + $4,
    stat_points_unspent = stat_points_unspent - $5,
    action_seq   = $6,
    last_seen_at = now()
WHERE id = $1 AND stat_points_unspent >= $5
RETURNING *;

-- name: SetAvatar :one
UPDATE app.players SET avatar = $2, action_seq = $3, last_seen_at = now()
WHERE id = $1 RETURNING *;

-- Finds someone to invite. Prefix match rather than substring, so a search is
-- index-friendly and a player cannot enumerate the roster by typing one letter.
--
-- Bots are excluded: they exist to fill the Attack tab and cannot accept.
-- name: FindInvitablePlayers :many
SELECT id, username, display_name, avatar, level, kingdom_id
FROM app.players
WHERE state = 'active'
  AND is_bot = false
  AND id <> $1
  AND lower(username) LIKE lower($2)
ORDER BY level DESC
LIMIT 20;
