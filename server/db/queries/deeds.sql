-- Deeds. See migration 00032.

-- Adds one action's counts to every scope it belongs to, in one statement: the
-- four arrays are parallel, one element per (scope, period, deed), and unnest
-- in a select list walks equal-length arrays together.
-- name: BumpDeeds :exec
INSERT INTO app.player_deeds (player_id, scope, period, deed, value)
SELECT sqlc.arg(player_id)::uuid,
       unnest(sqlc.arg(scopes)::text[]), unnest(sqlc.arg(periods)::bigint[]),
       unnest(sqlc.arg(deeds)::text[]), unnest(sqlc.arg(vals)::bigint[])
ON CONFLICT (player_id, scope, period, deed)
DO UPDATE SET value = app.player_deeds.value + EXCLUDED.value;

-- One scope's counters for a player.
-- name: ListDeeds :many
SELECT deed, value FROM app.player_deeds
WHERE player_id = sqlc.arg(player_id) AND scope = sqlc.arg(scope) AND period = sqlc.arg(period);
