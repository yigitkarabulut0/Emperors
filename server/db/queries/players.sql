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

-- Writes back a whole batch of players the presence registry has heard from.
--
-- This is what finally makes the comment in admin.sql true. last_seen_at was
-- only ever written as a side effect of the ~18 queries that MUTATE something,
-- so a player who opened the game, read their estates and put the phone down
-- was never recorded as active at all, and every "actives" number undercounted
-- everyone who was merely looking. The registry now records every authenticated
-- request in memory and flushes the set here once every thirty seconds -- one
-- statement regardless of how many players are online, instead of one write per
-- request.
-- name: TouchPlayersSeen :exec
UPDATE app.players SET last_seen_at = now() WHERE id = ANY($1::uuid[]);

-- The players seen recently, to repopulate the presence registry after a
-- restart. Without it a deploy shows every player leaving at once.
-- name: RecentlySeenPlayers :many
SELECT id, last_seen_at FROM app.players
WHERE last_seen_at > $1 AND NOT is_bot;

-- Spends level-up points. The WHERE clause carries the affordability check, so
-- the balance cannot go negative even under a concurrent double-tap.
-- name: SpendStatPoints :one
UPDATE app.players
SET stat_energy  = stat_energy  + $2,
    stat_attack  = stat_attack  + $3,
    stat_defense = stat_defense + $4,
    stat_points_unspent = stat_points_unspent - $5,
    action_seq   = $6
WHERE id = $1 AND stat_points_unspent >= $5
RETURNING *;

-- name: SetAvatar :one
UPDATE app.players SET avatar = $2, action_seq = $3
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

-- name: BumpActionSeq :one
UPDATE app.players SET action_seq = $2 WHERE id = $1 RETURNING *;
