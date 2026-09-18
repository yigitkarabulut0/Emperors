-- name: CreateKingdom :one
INSERT INTO app.kingdoms (name, tag, leader_id) VALUES ($1, $2, $3) RETURNING *;

-- Renames a kingdom, and only for its king. The WHERE carries the permission,
-- so a lord who reaches the endpoint gets no rows rather than a rename.
-- name: RenameKingdom :one
UPDATE app.kingdoms
SET name = sqlc.arg(name)
WHERE id = sqlc.arg(id) AND leader_id = sqlc.arg(leader_id)
RETURNING *;

-- name: GetKingdom :one
SELECT * FROM app.kingdoms WHERE id = $1;

-- name: LockKingdom :one
SELECT * FROM app.kingdoms WHERE id = $1 FOR UPDATE;

-- Ordered by rank then contribution, which is the order the roster should read:
-- who leads, then who has actually carried the kingdom.
-- name: ListKingdomMembers :many
SELECT id, display_name, avatar, level, kingdom_role, kingdom_joined_at,
       kingdom_donated_total, kingdom_favour,
       cos_frame, cos_title, cos_color, cos_crest, vip_points
FROM app.players
WHERE kingdom_id = $1
ORDER BY CASE kingdom_role WHEN 'king' THEN 0 WHEN 'marshal' THEN 1 ELSE 2 END,
         kingdom_donated_total DESC;

-- name: CountKingdomMembers :one
SELECT count(*) FROM app.players WHERE kingdom_id = $1;

-- Seats a player. The kingdom_id IS NULL guard is the last word on "one
-- kingdom at a time": a king answering a request seats someone other than
-- himself, and that someone may have joined elsewhere a moment before. Zero
-- rows means they had.
-- name: SetPlayerKingdom :one
UPDATE app.players
SET kingdom_id = $2, kingdom_role = $3, kingdom_joined_at = $4
WHERE id = $1 AND kingdom_id IS NULL
RETURNING *;

-- Founding: pay, and join in the same statement so a crash cannot leave a
-- kingdom with no king.
-- name: PayAndJoinKingdom :one
UPDATE app.players
SET gold = gold - $2, kingdom_id = $3, kingdom_role = $4,
    kingdom_joined_at = now(), action_seq = $5
WHERE id = $1 AND gold >= $2 AND kingdom_id IS NULL
RETURNING *;

-- Leaving stamps the time, which is what the rejoin cooldown is measured from.
-- name: LeaveKingdom :one
UPDATE app.players
SET kingdom_id = NULL, kingdom_role = 'none', kingdom_joined_at = NULL,
    kingdom_left_at = sqlc.arg(left_at)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Removal by a king or captain. Guarded by the kingdom, so a removal that races
-- the lord's own leave-and-join cannot take them out of the kingdom they moved to.
-- name: KickFromKingdom :one
UPDATE app.players
SET kingdom_id = NULL, kingdom_role = 'none', kingdom_joined_at = NULL,
    kingdom_left_at = sqlc.arg(left_at)
WHERE id = sqlc.arg(id) AND kingdom_id = sqlc.arg(kingdom_id)
RETURNING *;

-- A kingdom is deleted when its last lord leaves -- and only then. The guard is
-- not a courtesy: players_kingdom_role_consistent would abort a delete that
-- nulled a member's kingdom_id under a role that is still 'member'.
-- name: DeleteKingdomIfEmpty :execrows
DELETE FROM app.kingdoms k
WHERE k.id = $1
  AND NOT EXISTS (SELECT 1 FROM app.players p WHERE p.kingdom_id = k.id);

-- name: SetLeader :exec
UPDATE app.kingdoms SET leader_id = $2 WHERE id = $1;

-- name: SetJoinPolicy :exec
UPDATE app.kingdoms SET join_policy = $2 WHERE id = $1;

-- name: SetKingdomRole :one
UPDATE app.players SET kingdom_role = $2 WHERE id = $1 AND kingdom_id = $3 RETURNING *;

-- An invitation and a request share one row per (kingdom, player). Refreshing
-- an invitation must never turn a pending request into one -- the WHERE on the
-- update is what stops it -- so zero rows means a request was standing.
-- name: CreateInvite :execrows
INSERT INTO app.kingdom_invites (kingdom_id, player_id, invited_by, direction)
VALUES ($1, $2, $3, 'invite')
ON CONFLICT (kingdom_id, player_id) DO UPDATE
SET created_at = now(), invited_by = EXCLUDED.invited_by
WHERE app.kingdom_invites.direction = 'invite';

-- Only an invitation. Unscoped, /accept would seat a player in a kingdom they
-- had merely asked to join.
-- name: GetInvite :one
SELECT * FROM app.kingdom_invites
WHERE kingdom_id = $1 AND player_id = $2 AND direction = 'invite';

-- name: GetJoinRequest :one
SELECT * FROM app.kingdom_invites
WHERE kingdom_id = $1 AND player_id = $2 AND direction = 'request';

-- name: CreateJoinRequest :execrows
INSERT INTO app.kingdom_invites (kingdom_id, player_id, invited_by, direction)
VALUES ($1, $2, NULL, 'request')
ON CONFLICT (kingdom_id, player_id) DO NOTHING;

-- name: CountRequestsForPlayer :one
SELECT count(*) FROM app.kingdom_invites WHERE player_id = $1 AND direction = 'request';

-- name: ListRequestsForPlayer :many
SELECT kingdom_id FROM app.kingdom_invites WHERE player_id = $1 AND direction = 'request';

-- Who has asked to join, oldest first: the Lords tab answers them in order.
-- name: ListRequestsForKingdom :many
SELECT p.id, p.display_name, p.level, i.created_at, p.avatar,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.kingdom_invites i JOIN app.players p ON p.id = i.player_id
WHERE i.kingdom_id = $1 AND i.direction = 'request' AND p.kingdom_id IS NULL
ORDER BY i.created_at
LIMIT 50;

-- The invitations a kingdomless player holds, as cards: everything the hall
-- shows about a kingdom, so an invitation reads like any other kingdom.
-- name: ListInvitesForPlayer :many
SELECT k.id, k.name, k.tag, k.level, k.reputation, k.join_policy, i.created_at,
       (SELECT count(*) FROM app.players m WHERE m.kingdom_id = k.id)::int AS members,
       coalesce((SELECT u.level FROM app.kingdom_upgrades u
                 WHERE u.kingdom_id = k.id AND u.upgrade_id = sqlc.arg(court_id)), 0)::int AS court_level,
       coalesce((SELECT m.display_name FROM app.players m
                 WHERE m.kingdom_id = k.id AND m.kingdom_role = 'king' LIMIT 1), '')::text AS king_name
FROM app.kingdom_invites i JOIN app.kingdoms k ON k.id = i.kingdom_id
WHERE i.player_id = sqlc.arg(player_id) AND i.direction = 'invite'
ORDER BY i.created_at DESC;

-- name: DeleteInvite :execrows
DELETE FROM app.kingdom_invites WHERE kingdom_id = $1 AND player_id = $2 AND direction = $3;

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

-- The table. A kingdom whose last lord has gone is not a kingdom, so it is not
-- ranked, however much renown it left behind.
-- name: TopKingdoms :many
SELECT k.id, k.name, k.tag, k.level, k.xp, k.treasury, k.reputation, k.join_policy,
       (SELECT count(*) FROM app.players p WHERE p.kingdom_id = k.id)::int AS members,
       coalesce((SELECT u.level FROM app.kingdom_upgrades u
                 WHERE u.kingdom_id = k.id AND u.upgrade_id = sqlc.arg(court_id)), 0)::int AS court_level
FROM app.kingdoms k
WHERE EXISTS (SELECT 1 FROM app.players p WHERE p.kingdom_id = k.id)
ORDER BY k.reputation DESC, k.xp DESC
LIMIT sqlc.arg(max_rows);

-- Kingdoms by name or tag. The pattern arrives escaped and lower-cased from the
-- service ('%', '_' and '\' are literal in a name), and an exact tag reads first:
-- someone typing LION wants [LION], not every kingdom with a lion in its name.
-- name: SearchKingdoms :many
SELECT k.id, k.name, k.tag, k.level, k.reputation, k.join_policy,
       count(p.id)::int AS members,
       coalesce((SELECT u.level FROM app.kingdom_upgrades u
                 WHERE u.kingdom_id = k.id AND u.upgrade_id = sqlc.arg(court_id)), 0)::int AS court_level,
       coalesce(max(p.display_name) FILTER (WHERE p.kingdom_role = 'king'), '')::text AS king_name
FROM app.kingdoms k
JOIN app.players p ON p.kingdom_id = k.id
WHERE lower(k.name) LIKE sqlc.arg(pattern)::text ESCAPE '\'
   OR lower(k.tag) LIKE sqlc.arg(pattern)::text ESCAPE '\'
GROUP BY k.id
ORDER BY (lower(k.tag) = sqlc.arg(exact)::text) DESC, k.reputation DESC, k.level DESC
LIMIT 20;

-- Kingdoms worth suggesting to someone with none: every kingdom that still has
-- lords, the busiest first -- a kingdom whose members were here this week is a
-- kingdom that will answer, which a big quiet one will not -- then by renown.
-- The service drops the full ones against the real cap, Royal Court included,
-- which SQL cannot see; hence more candidates than it shows.
-- name: RecommendKingdoms :many
SELECT k.id, k.name, k.tag, k.level, k.reputation, k.join_policy,
       count(p.id)::int AS members,
       (count(p.id) FILTER (WHERE p.last_seen_at > sqlc.arg(active_since)))::int AS active,
       coalesce((SELECT u.level FROM app.kingdom_upgrades u
                 WHERE u.kingdom_id = k.id AND u.upgrade_id = sqlc.arg(court_id)), 0)::int AS court_level,
       coalesce(max(p.display_name) FILTER (WHERE p.kingdom_role = 'king'), '')::text AS king_name
FROM app.kingdoms k
JOIN app.players p ON p.kingdom_id = k.id
GROUP BY k.id
ORDER BY active DESC, k.reputation DESC, k.level DESC, k.created_at
LIMIT sqlc.arg(max_rows);

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

-- Who takes the crown when a king's account is deleted: the longest-serving
-- captain, else the longest-serving lord.
-- name: PickSuccessor :one
SELECT id FROM app.players
WHERE kingdom_id = sqlc.arg(kingdom_id) AND id <> sqlc.arg(king_id)
ORDER BY CASE kingdom_role WHEN 'marshal' THEN 0 ELSE 1 END,
         kingdom_joined_at ASC NULLS LAST, kingdom_donated_total DESC
LIMIT 1;
