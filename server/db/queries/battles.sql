-- Candidate opponents inside a level band, excluding the player, bots-or-not by
-- flag, the shielded, and anyone banned. Ordered by a stable pseudo-random key
-- so the list changes between refreshes without a table scan.
-- name: FindTargets :many
SELECT id, username, display_name, avatar, level, gold, is_bot, shield_until, kingdom_id
FROM app.players
WHERE state = 'active'
  AND id <> $1
  AND level BETWEEN $2 AND $3
  AND (shield_until IS NULL OR shield_until < now())
ORDER BY random()
LIMIT $4;

-- name: LockTwoPlayers :many
SELECT * FROM app.players WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE;

-- name: ApplyBattleAttacker :one
UPDATE app.players
SET gold = gold + $2, xp = $3, level = $4,
    stat_points_unspent = stat_points_unspent + $5,
    energy_milli = $6, energy_updated_at = $7,
    action_seq = $8
WHERE id = $1
RETURNING *;

-- name: ApplyBattleDefender :one
UPDATE app.players
SET gold = gold + $2, shield_until = $3
WHERE id = $1
RETURNING *;

-- name: InsertBattle :one
INSERT INTO app.battles (
    attacker_id, defender_id, seed, config_version, attacker_won, rounds,
    attacker_might, defender_might, gold_stolen, ransom_paid, xp_awarded,
    energy_spent, replay
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
RETURNING *;

-- name: GetBattle :one
SELECT * FROM app.battles WHERE id = $1;

-- name: ListBattles :many
SELECT * FROM app.battles
WHERE attacker_id = $1 OR defender_id = $1
ORDER BY created_at DESC
LIMIT $2;

-- name: GetCooldown :one
SELECT * FROM app.attack_cooldowns WHERE attacker_id = $1 AND defender_id = $2;

-- name: TouchCooldown :exec
INSERT INTO app.attack_cooldowns (attacker_id, defender_id, last_at, count_24h)
VALUES ($1, $2, now(), 1)
ON CONFLICT (attacker_id, defender_id) DO UPDATE
SET last_at = now(),
    count_24h = CASE WHEN app.attack_cooldowns.last_at > now() - interval '24 hours'
                     THEN app.attack_cooldowns.count_24h + 1 ELSE 1 END;

-- name: CreateBot :one
INSERT INTO app.players (username, display_name, level, gold, is_bot, soldier_slots,
                         stat_attack, stat_defense, energy_milli, avatar)
VALUES ($1,$2,$3,$4,true,$5,$6,$7,0,$8)
RETURNING *;

-- name: CountBots :one
SELECT count(*) FROM app.players WHERE is_bot;
