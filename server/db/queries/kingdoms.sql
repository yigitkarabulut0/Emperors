-- name: CreateKingdom :one
INSERT INTO app.kingdoms (name, tag, leader_id) VALUES ($1, $2, $3) RETURNING *;

-- name: GetKingdom :one
SELECT * FROM app.kingdoms WHERE id = $1;

-- name: LockKingdom :one
SELECT * FROM app.kingdoms WHERE id = $1 FOR UPDATE;

-- Ordered by rank then contribution, which is the order the roster should read:
-- who leads, then who has actually carried the kingdom.
-- name: ListKingdomMembers :many
SELECT id, display_name, level, kingdom_role, kingdom_joined_at,
       kingdom_donated_total, kingdom_favour
FROM app.players
WHERE kingdom_id = $1
ORDER BY CASE kingdom_role WHEN 'king' THEN 0 WHEN 'marshal' THEN 1 ELSE 2 END,
         kingdom_donated_total DESC;

-- name: CountKingdomMembers :one
SELECT count(*) FROM app.players WHERE kingdom_id = $1;

-- name: SetPlayerKingdom :one
UPDATE app.players
SET kingdom_id = $2, kingdom_role = $3, kingdom_joined_at = $4
WHERE id = $1
RETURNING *;

-- Founding: pay, and join in the same statement so a crash cannot leave a
-- kingdom with no king.
-- name: PayAndJoinKingdom :one
UPDATE app.players
SET gold = gold - $2, kingdom_id = $3, kingdom_role = $4,
    kingdom_joined_at = now(), action_seq = $5
WHERE id = $1 AND gold >= $2 AND kingdom_id IS NULL
RETURNING *;

-- name: LeaveKingdom :one
UPDATE app.players
SET kingdom_id = NULL, kingdom_role = 'none', kingdom_joined_at = NULL
WHERE id = $1
RETURNING *;

-- name: SetKingdomRole :one
UPDATE app.players SET kingdom_role = $2 WHERE id = $1 AND kingdom_id = $3 RETURNING *;

-- name: CreateInvite :exec
INSERT INTO app.kingdom_invites (kingdom_id, player_id, invited_by)
VALUES ($1, $2, $3)
ON CONFLICT (kingdom_id, player_id) DO UPDATE SET created_at = now(), invited_by = EXCLUDED.invited_by;

-- name: GetInvite :one
SELECT * FROM app.kingdom_invites WHERE kingdom_id = $1 AND player_id = $2;

-- name: ListInvitesForPlayer :many
SELECT i.kingdom_id, i.created_at, k.name, k.tag, k.level, k.reputation
FROM app.kingdom_invites i JOIN app.kingdoms k ON k.id = i.kingdom_id
WHERE i.player_id = $1
ORDER BY i.created_at DESC;

-- name: DeleteInvite :exec
DELETE FROM app.kingdom_invites WHERE kingdom_id = $1 AND player_id = $2;

-- name: DeleteInvitesForPlayer :exec
DELETE FROM app.kingdom_invites WHERE player_id = $1;

-- Donating: take the gold, credit the treasury, and record the daily total in
-- one place so the cap cannot be bypassed by racing two requests.
-- name: DonateGold :one
UPDATE app.players
SET gold = gold - $2,
    kingdom_donated_total = kingdom_donated_total + $2,
    kingdom_donated_today = CASE WHEN kingdom_day = $3 THEN kingdom_donated_today + $2 ELSE $2 END,
    kingdom_day = $3,
    kingdom_favour = kingdom_favour + $4,
    action_seq = $5
WHERE id = $1 AND gold >= $2
RETURNING *;

-- name: AddKingdomTreasury :one
UPDATE app.kingdoms
SET treasury = treasury + $2, xp = xp + $3, level = $4
WHERE id = $1
RETURNING *;

-- name: SpendKingdomTreasury :one
UPDATE app.kingdoms SET treasury = treasury - $2 WHERE id = $1 AND treasury >= $2 RETURNING *;

-- name: ListKingdomUpgrades :many
SELECT * FROM app.kingdom_upgrades WHERE kingdom_id = $1;

-- name: BuyKingdomUpgradeLevel :one
INSERT INTO app.kingdom_upgrades (kingdom_id, upgrade_id, level)
VALUES ($1, $2, 1)
ON CONFLICT (kingdom_id, upgrade_id) DO UPDATE
SET level = app.kingdom_upgrades.level + 1
WHERE app.kingdom_upgrades.level = $3
RETURNING *;

-- Reputation from a raid, honouring the per-member daily cap.
-- name: AddKingdomReputation :exec
UPDATE app.kingdoms SET reputation = reputation + $2 WHERE id = $1;

-- name: BumpMemberReputation :one
UPDATE app.players
SET kingdom_rep_today = CASE WHEN kingdom_day = $3 THEN kingdom_rep_today + $2 ELSE $2 END,
    kingdom_day = $3
WHERE id = $1
RETURNING *;

-- name: TopKingdoms :many
SELECT k.*, (SELECT count(*) FROM app.players p WHERE p.kingdom_id = k.id) AS members
FROM app.kingdoms k
ORDER BY k.reputation DESC, k.xp DESC
LIMIT $1;

-- name: SearchKingdoms :many
SELECT k.*, (SELECT count(*) FROM app.players p WHERE p.kingdom_id = k.id) AS members
FROM app.kingdoms k
WHERE lower(k.name) LIKE lower($1) OR lower(k.tag) LIKE lower($1)
ORDER BY k.reputation DESC
LIMIT 20;

-- Nightly decay. 2% a day is what stops a kingdom that quit in month one from
-- squatting at rank 1 forever.
-- name: DecayReputation :exec
UPDATE app.kingdoms SET reputation = reputation * (10000 - $1) / 10000 WHERE reputation > 0;

-- Claims one calendar day's reputation decay, atomically.
--
-- The whole point is the WHERE: two API replicas, or one that restarted twice in
-- an evening, must not both decay the same day. The insert only lands when the
-- stored marker is behind the day being claimed, so whoever gets there first
-- does the work and everyone else gets zero rows back.
-- name: ClaimDecayDay :one
INSERT INTO app.server_info (key, value, updated_at)
VALUES ('reputation_decay_day', sqlc.arg(day), now())
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, updated_at = now()
WHERE app.server_info.value < EXCLUDED.value
RETURNING value;

-- Spends favour. Zero rows means they could not afford it, so the check and the
-- deduction are the same statement and a double-tap cannot overdraw.
-- name: SpendFavour :one
UPDATE app.players
SET kingdom_favour = kingdom_favour - sqlc.arg(cost), action_seq = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id) AND kingdom_favour >= sqlc.arg(cost)
RETURNING *;

-- name: GrantXPBoost :exec
UPDATE app.players
SET xp_boost_bp = sqlc.arg(bp), xp_boost_expires_at = sqlc.arg(expires_at)
WHERE id = sqlc.arg(id);

-- name: RefillEnergy :exec
UPDATE app.players
SET energy_milli = sqlc.arg(energy_milli), energy_updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);
