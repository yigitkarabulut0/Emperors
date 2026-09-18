-- Deleted accounts, player days and the client's events. See migration 00033.

-- What outlives a deleted account: its id, when it came and went, and what it
-- held. Written in the deletion's own transaction, before the player row goes.
-- name: RecordDeletedAccount :exec
INSERT INTO app.deleted_accounts (player_id, joined_at, deleted_at, level, diamonds, diamond_debt)
VALUES (sqlc.arg(player_id), sqlc.arg(joined_at), sqlc.arg(deleted_at), sqlc.arg(level),
        sqlc.arg(diamonds), sqlc.arg(diamond_debt));

-- name: GetDeletedAccount :one
SELECT * FROM app.deleted_accounts WHERE player_id = sqlc.arg(player_id);

-- A deleted account's events go with it. Its days stay: they happened, and a
-- cohort that forgets the players who left reports its retention too high.
-- name: DeletePlayerEvents :exec
DELETE FROM app.analytics_events WHERE player_id = sqlc.arg(player_id);

-- The diamond history of accounts deleted before a cutoff. A refund that comes
-- after this finds the deleted_accounts row and nothing to take back.
-- name: PurgeDeletedLedger :execrows
DELETE FROM app.diamond_ledger l
USING app.deleted_accounts d
WHERE l.player_id = d.player_id AND d.deleted_at < sqlc.arg(before)::timestamptz;

-- One call's events, in one statement, unless the player has already sent their
-- hour's allowance. The arrays are parallel; unnest in a select list walks them
-- together. props arrive as JSON text; an at of 0 is "the phone's clock was not
-- believable".
-- name: RecordEvents :execrows
INSERT INTO app.analytics_events (player_id, name, props, client_at)
SELECT sqlc.arg(player_id)::uuid, e.name, e.props::jsonb,
       CASE WHEN e.at > 0 THEN to_timestamp(e.at) END
FROM (SELECT unnest(sqlc.arg(names)::text[])  AS name,
             unnest(sqlc.arg(props)::text[])  AS props,
             unnest(sqlc.arg(ats)::bigint[])  AS at) e
WHERE (SELECT count(*) FROM app.analytics_events x
       WHERE x.player_id = sqlc.arg(player_id)::uuid
         AND x.created_at > sqlc.arg(now)::timestamptz - interval '1 hour') < sqlc.arg(hourly_cap)::int;

-- name: PurgeEvents :execrows
DELETE FROM app.analytics_events WHERE created_at < sqlc.arg(before)::timestamptz;

-- name: PurgePlayerDays :execrows
DELETE FROM app.player_days WHERE day < sqlc.arg(before)::date;

-- Classic retention by the UTC day players joined: of those who joined on a day,
-- how many were here exactly one, seven and thirty days later. Deleted accounts
-- stay in the cohort they joined. Bots never send a request, so never join one.
-- name: RetentionCohorts :many
WITH joined AS (
    SELECT id AS player_id, (created_at AT TIME ZONE 'UTC')::date AS day
    FROM app.players WHERE NOT is_bot
    UNION ALL
    SELECT player_id, (joined_at AT TIME ZONE 'UTC')::date FROM app.deleted_accounts
)
SELECT j.day::date AS day,
       count(*)::bigint AS size,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM app.player_days d
                                      WHERE d.player_id = j.player_id AND d.day = j.day + 1))::bigint AS d1,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM app.player_days d
                                      WHERE d.player_id = j.player_id AND d.day = j.day + 7))::bigint AS d7,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM app.player_days d
                                      WHERE d.player_id = j.player_id AND d.day = j.day + 30))::bigint AS d30
FROM joined j
WHERE j.day >= sqlc.arg(since)::date
GROUP BY j.day
ORDER BY j.day DESC;

-- Each event name over a window: how often, and by how many players.
-- name: EventCounts :many
SELECT name, count(*)::bigint AS events, count(DISTINCT player_id)::bigint AS players
FROM app.analytics_events
WHERE created_at > sqlc.arg(since)::timestamptz
GROUP BY name
ORDER BY count(*) DESC;

-- The screens opened over a window, most visited first.
-- name: ScreenCounts :many
SELECT coalesce(props->>'name', '')::text AS screen, count(*)::bigint AS views,
       count(DISTINCT player_id)::bigint AS players
FROM app.analytics_events
WHERE name = 'screen' AND created_at > sqlc.arg(since)::timestamptz
GROUP BY props->>'name'
ORDER BY count(*) DESC
LIMIT 40;

-- How long sessions last, in bands, from the phone's own count of its time in
-- the foreground. The bands are the panel's rows.
-- name: SessionLengths :many
SELECT CASE WHEN s < 60 THEN 0 WHEN s < 180 THEN 1 WHEN s < 600 THEN 2
            WHEN s < 1800 THEN 3 ELSE 4 END::int AS band,
       count(*)::bigint AS sessions
FROM (SELECT (props->>'seconds')::bigint AS s FROM app.analytics_events
      WHERE name = 'app_close' AND created_at > sqlc.arg(since)::timestamptz) x
GROUP BY 1
ORDER BY 1;
