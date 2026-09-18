-- Candidate opponents inside a level band, excluding the player, bots-or-not by
-- flag, the shielded, and anyone banned. Ordered by a stable pseudo-random key
-- so the list changes between refreshes without a table scan.
-- name: FindTargets :many
SELECT id, username, display_name, avatar, level, gold, is_bot, shield_until, kingdom_id,
       cos_frame, cos_title, cos_color, cos_crest, vip_points
FROM app.players
WHERE state = 'active'
  AND id <> $1
  AND level BETWEEN $2 AND $3
  AND (shield_until IS NULL OR shield_until < now())
ORDER BY random()
LIMIT $4;

-- name: LockTwoPlayers :many
SELECT * FROM app.players WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE;

-- Diamonds are the level-up grant, the same one a collect pays: a level reached
-- in a raid is a level reached.
--
-- The attacker's shield is written every time, never left alone: raiding ends
-- your own protection (a revenge strike keeps it), so the caller passes NULL for
-- an ordinary raid and the current value for a revenge one.
-- name: ApplyBattleAttacker :one
UPDATE app.players
SET gold = gold + $2, xp = $3, level = $4,
    stat_points_unspent = stat_points_unspent + $5,
    energy_milli = $6, energy_updated_at = $7,
    action_seq = $8,
    diamonds = diamonds + GREATEST(0, sqlc.arg(diamonds)::bigint - diamond_debt),
    diamond_debt = GREATEST(0, diamond_debt - sqlc.arg(diamonds)::bigint),
    shield_until = sqlc.narg(shield_until)
WHERE id = $1
RETURNING *;

-- name: ApplyBattleDefender :one
UPDATE app.players
SET gold = gold + $2, shield_until = $3
WHERE id = $1
RETURNING *;

-- The id is supplied, not defaulted.
--
-- It is minted in Go before the fight because the combat seed is derived from
-- it, and it is what the attack response hands the client. Letting the database
-- default a different one meant the id the player was given did not name any
-- stored row: every replay link was dead, and nothing could reference the battle
-- afterwards.
-- name: InsertBattle :one
INSERT INTO app.battles (
    id, attacker_id, defender_id, seed, config_version, attacker_won, rounds,
    attacker_might, defender_might, gold_stolen, ransom_paid, xp_awarded,
    energy_spent, replay, kind
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
RETURNING *;

-- name: GetBattle :one
SELECT * FROM app.battles WHERE id = $1;

-- name: ListBattles :many
SELECT * FROM app.battles
WHERE attacker_id = $1 OR defender_id = $1
ORDER BY created_at DESC
LIMIT $2;

-- Battle history with the OTHER party's identity resolved in the same round
-- trip. A log that says "you lost 4,120 gold" without saying to whom is not a
-- log, and fetching the names separately would be one query per row.
--
-- The join key flips on which side the player was: their opponent is the
-- defender when they attacked, and the attacker when they were raided.
-- name: ListBattleLog :many
SELECT b.id, b.attacker_id, b.defender_id, b.attacker_won, b.rounds,
       b.attacker_might, b.defender_might, b.gold_stolen, b.ransom_paid,
       b.xp_awarded, b.created_at,
       o.display_name AS opponent_name,
       o.avatar       AS opponent_avatar,
       o.level        AS opponent_level,
       o.is_bot       AS opponent_is_bot,
       o.cos_frame    AS opponent_cos_frame,
       o.cos_title    AS opponent_cos_title,
       o.cos_color    AS opponent_cos_color,
       o.cos_crest    AS opponent_cos_crest,
       o.vip_points   AS opponent_vip_points
FROM app.battles b
JOIN app.players o
  ON o.id = CASE WHEN b.attacker_id = sqlc.arg(player_id) THEN b.defender_id
                 ELSE b.attacker_id END
WHERE (b.attacker_id = sqlc.arg(player_id) OR b.defender_id = sqlc.arg(player_id))
  AND b.kind = 'raid'
ORDER BY b.created_at DESC
LIMIT sqlc.arg(lim);

-- The lists' own recent fights. Kept apart from the raid log on purpose: an
-- arena defeat costs nothing but a rating, and reading it in the same column as
-- "you were robbed" is how a screen starts to lie.
-- name: ListArenaLog :many
SELECT b.id, b.attacker_id, b.attacker_won, b.created_at,
       o.display_name AS opponent_name,
       o.avatar       AS opponent_avatar
FROM app.battles b
JOIN app.players o
  ON o.id = CASE WHEN b.attacker_id = sqlc.arg(player_id) THEN b.defender_id
                 ELSE b.attacker_id END
WHERE (b.attacker_id = sqlc.arg(player_id) OR b.defender_id = sqlc.arg(player_id))
  AND b.kind = 'arena'
ORDER BY b.created_at DESC
LIMIT sqlc.arg(lim);

-- How many raids landed on this player since a given moment, for the
-- "while you were away" summary. Counts only fights they did not start.
-- name: CountRaidsSince :one
SELECT count(*) AS raids,
       coalesce(sum(b.gold_stolen), 0)::bigint AS gold_lost,
       coalesce(sum(b.ransom_paid), 0)::bigint AS ransom_earned
FROM app.battles b
WHERE b.defender_id = sqlc.arg(player_id)
  AND b.kind = 'raid'
  AND b.created_at > sqlc.arg(since)::timestamptz;

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

-- name: GrantRevenge :exec
INSERT INTO app.revenge_tokens (battle_id, player_id, target_id, expires_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (battle_id) DO NOTHING;

-- Live, unspent tokens with the person to be avenged upon resolved in the same
-- round trip.
-- name: ListRevenge :many
SELECT r.battle_id, r.target_id, r.expires_at,
       t.display_name AS target_name,
       t.avatar       AS target_avatar,
       t.level        AS target_level,
       t.gold         AS target_gold,
       t.kingdom_id   AS target_kingdom_id,
       t.cos_frame    AS target_cos_frame,
       t.cos_title    AS target_cos_title,
       t.cos_color    AS target_cos_color,
       t.cos_crest    AS target_cos_crest,
       t.vip_points   AS target_vip_points
FROM app.revenge_tokens r
JOIN app.players t ON t.id = r.target_id
WHERE r.player_id = sqlc.arg(player_id)
  AND r.used_at IS NULL
  AND r.expires_at > now()
ORDER BY r.expires_at ASC;

-- Spends a token, and only if it is still live and still theirs. Zero rows means
-- it was already used or has expired, so the check and the spend cannot race.
-- name: UseRevenge :one
UPDATE app.revenge_tokens
SET used_at = now()
WHERE player_id = sqlc.arg(player_id) AND target_id = sqlc.arg(target_id)
  AND used_at IS NULL AND expires_at > now()
RETURNING battle_id;
