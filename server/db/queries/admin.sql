-- name: CreateAdminUser :one
INSERT INTO admin.users (username, password_hash, role) VALUES ($1,$2,$3) RETURNING *;

-- name: GetAdminByUsername :one
SELECT * FROM admin.users WHERE lower(username) = lower($1);

-- name: GetAdminByID :one
SELECT * FROM admin.users WHERE id = $1;

-- name: TouchAdminLogin :exec
UPDATE admin.users SET last_login_at = now() WHERE id = $1;

-- name: CountAdmins :one
SELECT count(*) FROM admin.users;

-- name: CreateAdminSession :one
INSERT INTO admin.sessions (admin_id, token_hash, expires_at) VALUES ($1,$2,$3) RETURNING *;

-- name: GetAdminSession :one
SELECT s.*, u.username, u.role, u.disabled
FROM admin.sessions s JOIN admin.users u ON u.id = s.admin_id
WHERE s.token_hash = $1;

-- name: RevokeAdminSession :exec
UPDATE admin.sessions SET revoked_at = now() WHERE token_hash = $1;

-- name: WriteAudit :exec
INSERT INTO admin.audit_log (admin_id, admin_name, action, subject, before, after, note)
VALUES ($1,$2,$3,$4,$5,$6,$7);

-- name: ListAudit :many
SELECT * FROM admin.audit_log ORDER BY created_at DESC LIMIT $1;

-- name: SearchPlayers :many
SELECT id, username, display_name, level, gold, diamonds, state, is_bot,
       kingdom_id, created_at, last_seen_at
FROM app.players
WHERE lower(username) LIKE lower($1) OR lower(display_name) LIKE lower($1)
ORDER BY last_seen_at DESC
LIMIT 50;

-- name: AdminSetPlayerState :one
UPDATE app.players SET state = $2 WHERE id = $1 RETURNING *;

-- name: AdminAdjustCurrency :one
UPDATE app.players SET gold = gold + $2, diamonds = diamonds + $3 WHERE id = $1 RETURNING *;

-- Economy health: what created gold and what destroyed it, by reason.
-- name: GoldFlows :many
SELECT reason,
       sum(CASE WHEN delta > 0 THEN delta ELSE 0 END)::bigint AS created,
       sum(CASE WHEN delta < 0 THEN -delta ELSE 0 END)::bigint AS destroyed,
       count(*)::bigint AS entries
FROM app.gold_ledger
WHERE created_at > now() - ($1::int * interval '1 day')
GROUP BY reason
ORDER BY greatest(sum(CASE WHEN delta > 0 THEN delta ELSE 0 END),
                  sum(CASE WHEN delta < 0 THEN -delta ELSE 0 END)) DESC;

-- name: PlayerCounts :one
SELECT
  count(*) FILTER (WHERE NOT is_bot)::bigint AS players,
  count(*) FILTER (WHERE is_bot)::bigint AS bots,
  count(*) FILTER (WHERE NOT is_bot AND last_seen_at > now() - interval '1 day')::bigint AS active_1d,
  count(*) FILTER (WHERE NOT is_bot AND last_seen_at > now() - interval '7 days')::bigint AS active_7d,
  count(*) FILTER (WHERE NOT is_bot AND created_at > now() - interval '1 day')::bigint AS new_1d,
  coalesce(sum(gold) FILTER (WHERE NOT is_bot), 0)::bigint AS gold_held,
  coalesce(avg(level) FILTER (WHERE NOT is_bot), 0)::float AS avg_level
FROM app.players;

-- name: BattleStats :one
SELECT
  count(*)::bigint AS battles,
  count(*) FILTER (WHERE attacker_won)::bigint AS attacker_wins,
  coalesce(sum(gold_stolen), 0)::bigint AS gold_moved,
  coalesce(avg(rounds), 0)::float AS avg_rounds
FROM app.battles
WHERE created_at > now() - ($1::int * interval '1 day');

-- Adjusts the four stock quantities in one statement, so a grant of several at
-- once is a single row change and a single audit entry rather than four that
-- could half-apply.
--
-- XP is a delta into the CURRENT level's bar. It deliberately does not level
-- anyone up: crossing a boundary grants stat points, diamonds and an energy
-- refill, and a panel that silently did all that would be a very surprising
-- "+500 xp". Levels are their own control.
-- name: AdminAdjustPlayer :one
UPDATE app.players
SET gold                = gold + sqlc.arg(gold)::bigint,
    diamonds            = diamonds + sqlc.arg(diamonds)::bigint,
    xp                  = GREATEST(0, xp + sqlc.arg(xp)::bigint),
    stat_points_unspent = GREATEST(0, stat_points_unspent + sqlc.arg(stat_points)::int)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Sets the level outright, and refills energy the way a real level-up does.
-- The XP bar is reset to the bottom of the new level rather than carried, since
-- an xp value from another level means nothing.
-- name: AdminSetLevel :one
UPDATE app.players
SET level = sqlc.arg(level)::int,
    xp    = 0
WHERE id = sqlc.arg(id)
RETURNING *;

-- Energy is (value, anchor): writing the value without moving the anchor would
-- have the next settle immediately undo it, so both move together.
-- name: AdminSetEnergy :one
UPDATE app.players
SET energy_milli      = sqlc.arg(energy_milli)::bigint,
    energy_updated_at = sqlc.arg(now)::timestamptz
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: AdminSetLuck :one
UPDATE app.players
SET luck_bp         = sqlc.arg(luck_bp)::int,
    luck_expires_at = sqlc.arg(expires_at)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Everything the detail page shows about one player.
-- name: AdminGetPlayer :one
SELECT * FROM app.players WHERE id = $1;

-- That player's own history, newest first, rather than the whole trail.
-- name: AuditForSubject :many
SELECT * FROM admin.audit_log
WHERE subject = $1
ORDER BY created_at DESC
LIMIT $2;

-- Every boost in force at this instant. Read on a poll, never per request.
-- name: ActiveBoosts :many
SELECT bucket, sum(amount_bp)::bigint AS amount_bp
FROM admin.server_boosts
WHERE revoked_at IS NULL
  AND starts_at <= sqlc.arg(now)::timestamptz
  AND ends_at   >  sqlc.arg(now)::timestamptz
GROUP BY bucket;

-- name: CreateBoost :one
INSERT INTO admin.server_boosts (bucket, amount_bp, starts_at, ends_at, note, created_by)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- Revoked, never deleted: "why was everyone earning double on the 14th" has to
-- stay answerable long after the event.
-- name: RevokeBoost :one
UPDATE admin.server_boosts
SET revoked_at = now(), revoked_by = sqlc.arg(revoked_by)
WHERE id = sqlc.arg(id) AND revoked_at IS NULL
RETURNING *;

-- name: ListBoosts :many
SELECT * FROM admin.server_boosts ORDER BY starts_at DESC LIMIT $1;
