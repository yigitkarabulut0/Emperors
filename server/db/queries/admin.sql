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
--
-- The guards are in the WHERE: no row comes back when the grant would leave a
-- negative purse, so the panel reports "out of range" instead of the CHECK
-- constraint surfacing as a 500. A positive diamond grant repays refund debt
-- first, exactly as every other credit does; a removal only ever takes what is
-- there.
-- name: AdminAdjustPlayer :one
UPDATE app.players
SET gold                = gold + sqlc.arg(gold)::bigint,
    diamonds            = CASE WHEN sqlc.arg(diamonds)::bigint >= 0
                               THEN diamonds + GREATEST(0, sqlc.arg(diamonds)::bigint - diamond_debt)
                               ELSE diamonds + sqlc.arg(diamonds)::bigint END,
    diamond_debt        = CASE WHEN sqlc.arg(diamonds)::bigint >= 0
                               THEN GREATEST(0, diamond_debt - sqlc.arg(diamonds)::bigint)
                               ELSE diamond_debt END,
    xp                  = GREATEST(0, xp + sqlc.arg(xp)::bigint),
    stat_points_unspent = GREATEST(0, stat_points_unspent + sqlc.arg(stat_points)::int)
WHERE id = sqlc.arg(id)
  AND gold + sqlc.arg(gold)::bigint >= 0
  AND diamonds + LEAST(sqlc.arg(diamonds)::bigint, 0) >= 0
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

-- Every boost in force at this instant, per bucket, with when the first of
-- them ends. Read on a poll, never per request.
-- name: ActiveBoosts :many
SELECT bucket, sum(amount_bp)::bigint AS amount_bp, min(ends_at)::timestamptz AS ends_at
FROM admin.server_boosts
WHERE revoked_at IS NULL
  AND starts_at <= sqlc.arg(now)::timestamptz
  AND ends_at   >  sqlc.arg(now)::timestamptz
GROUP BY bucket;

-- Boosts an operator has scheduled to start within the window, soonest first:
-- what the game can announce before it begins.
-- name: UpcomingBoosts :many
SELECT bucket, amount_bp, starts_at, ends_at
FROM admin.server_boosts
WHERE revoked_at IS NULL
  AND starts_at >  sqlc.arg(now)::timestamptz
  AND starts_at <= sqlc.arg(until)::timestamptz
ORDER BY starts_at
LIMIT 10;

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

-- Registrations per day. generate_series so a day with no signups is a zero in
-- the chart rather than a missing bar that silently narrows the axis.
-- name: RegistrationsDaily :many
SELECT d::date AS day,
       count(p.id)::bigint AS count
FROM generate_series(
        (sqlc.arg(now)::timestamptz - make_interval(days => sqlc.arg(days)::int))::date,
        sqlc.arg(now)::timestamptz::date, '1 day') AS d
LEFT JOIN app.players p
       ON p.created_at::date = d::date AND NOT p.is_bot
GROUP BY d
ORDER BY d;

-- Players who played on each day: everyone who sent an authenticated request
-- that UTC day, from app.player_days.
--
-- This used to count last_seen_at, which is one timestamp per player: each
-- player was counted only on the day they were LAST seen, so a player who came
-- every day showed up once, on today, and every past day of the series was an
-- undercount that grew the further back it went. player_days keeps every day.
-- Days before migration 00033 hold only each player's joining day and last day.
-- name: ActiveDaily :many
SELECT d::date AS day,
       count(pd.player_id)::bigint AS count
FROM generate_series(
        (sqlc.arg(now)::timestamptz - make_interval(days => sqlc.arg(days)::int))::date,
        sqlc.arg(now)::timestamptz::date, '1 day') AS d
LEFT JOIN app.player_days pd ON pd.day = d::date
GROUP BY d
ORDER BY d;

-- Who is here right now.
-- name: OnlineNow :many
SELECT id, username, display_name, level, gold, diamonds, state, last_seen_at
FROM app.players
WHERE NOT is_bot AND last_seen_at > sqlc.arg(since)::timestamptz
ORDER BY last_seen_at DESC
LIMIT 50;

-- How the population is spread across the level ladder, in bands of ten.
-- name: LevelBands :many
SELECT (level / 10 * 10)::int AS band, count(*)::bigint AS count
FROM app.players
WHERE NOT is_bot
GROUP BY band
ORDER BY band;

-- The browsable list: filterable, sortable, paged.
--
-- One query with switched ORDER BY rather than six near-identical ones. The
-- sort keys are a fixed set from the handler, never anything a caller types.
-- name: BrowsePlayers :many
SELECT id, username, display_name, level, gold, diamonds, state, is_bot,
       luck_bp, created_at, last_seen_at,
       count(*) OVER ()::bigint AS total
FROM app.players
WHERE (sqlc.arg(q)::text = '' OR username ILIKE '%' || sqlc.arg(q)::text || '%'
                              OR display_name ILIKE '%' || sqlc.arg(q)::text || '%')
  AND (sqlc.arg(state)::text = '' OR state = sqlc.arg(state)::text)
  AND (sqlc.arg(include_bots)::bool OR NOT is_bot)
  AND level >= sqlc.arg(min_level)::int
ORDER BY
  CASE WHEN sqlc.arg(sort)::text = 'last_seen' THEN last_seen_at END DESC,
  CASE WHEN sqlc.arg(sort)::text = 'created'   THEN created_at   END DESC,
  CASE WHEN sqlc.arg(sort)::text = 'level'     THEN level        END DESC,
  CASE WHEN sqlc.arg(sort)::text = 'gold'      THEN gold         END DESC,
  id
LIMIT sqlc.arg(lim)::int OFFSET sqlc.arg(off)::int;

-- The identity behind a set of presence entries.
--
-- The live board is held in memory and knows only player ids, so rendering it
-- needs one lookup for the whole set rather than one per row.
-- name: PlayersByIDs :many
SELECT id, username, display_name, level, gold, diamonds, state, is_bot, last_seen_at, created_at
FROM app.players
WHERE id = ANY($1::uuid[]);

-- How many accounts exist at all, for the "of N registered" denominator.
-- name: TotalRegistered :one
SELECT count(*)::bigint FROM app.players WHERE NOT is_bot;
