-- The daily loop (migration 00041): the Tax Cart, the 28-day calendar, the
-- week's quests, the Golden Hour, the Victory Road, the guide, welcome back.

-- The Tax Cart's yard after a settle or an opening. opened is how many carts
-- this statement opened (0 for a settle alone).
-- name: SetCartYard :one
UPDATE app.players
SET cart_stock = sqlc.arg(stock), cart_at = sqlc.arg(at),
    carts_opened = carts_opened + sqlc.arg(opened)::int
WHERE id = sqlc.arg(id)
RETURNING *;

-- Takes today's square. The rule lives in the WHERE: it lands only when the
-- lord has not claimed on this local date, so two taps or two devices cannot
-- both take it. The square's reward is paid by the caller through grantBundle.
-- name: ClaimCalendarDay :one
UPDATE app.players
SET daily_streak     = sqlc.arg(streak),
    daily_claimed_on = sqlc.arg(today),
    calendar_pos     = sqlc.arg(pos),
    calendar_cycle   = sqlc.arg(cycle)
WHERE id = sqlc.arg(id)
  AND (daily_claimed_on IS NULL OR daily_claimed_on < sqlc.arg(today))
RETURNING *;

-- The week's board as it stands, if it has been drawn: read first, so the
-- heartbeat's badge stays a read.
-- name: GetWeekly :one
SELECT * FROM app.player_weekly WHERE player_id = sqlc.arg(player_id) AND week = sqlc.arg(week);

-- The week's board, drawn on its first look and frozen for the week.
-- name: EnsureWeekly :one
INSERT INTO app.player_weekly (player_id, week, task_ids)
VALUES (sqlc.arg(player_id), sqlc.arg(week), sqlc.arg(task_ids)::text[])
ON CONFLICT (player_id, week) DO UPDATE SET task_ids = app.player_weekly.task_ids
RETURNING *;

-- Setting the slot's bit is the claim; zero rows means it was already set.
-- name: ClaimWeeklyTask :one
UPDATE app.player_weekly
SET claimed = claimed | sqlc.arg(bit)::int, points = points + sqlc.arg(points)::int
WHERE player_id = sqlc.arg(player_id) AND week = sqlc.arg(week) AND claimed & sqlc.arg(bit)::int = 0
RETURNING *;

-- A chest opens once, and only on points already earned.
-- name: ClaimWeeklyChest :one
UPDATE app.player_weekly
SET chests = chests | sqlc.arg(bit)::int
WHERE player_id = sqlc.arg(player_id) AND week = sqlc.arg(week)
  AND chests & sqlc.arg(bit)::int = 0 AND points >= sqlc.arg(at)::int
RETURNING *;

-- The Golden Hour's state after a collect (game/frenzy.Step).
-- name: SetFrenzy :exec
UPDATE app.players
SET frenzy_meter_milli = sqlc.arg(meter_milli),
    frenzy_last_at     = sqlc.narg(last_at),
    frenzy_until       = sqlc.narg(until),
    frenzy_energy_left = sqlc.arg(energy_left),
    frenzy_day         = sqlc.narg(day),
    frenzy_used        = sqlc.arg(used),
    frenzy_ready_at    = sqlc.narg(ready_at)
WHERE id = sqlc.arg(id);

-- Claims Victory Road milestones: every bit must still be clear, so a claim
-- raced by another pays once.
-- name: ClaimRoad :one
UPDATE app.players
SET road_claimed = road_claimed | sqlc.arg(mask)::int
WHERE id = sqlc.arg(id) AND road_claimed & sqlc.arg(mask)::int = 0
RETURNING *;

-- Moves the guide from one step to the next, or ends it. The WHERE pins the
-- step it moves from, so a double tap moves it once.
-- name: MoveGuide :one
UPDATE app.players
SET guide_step = sqlc.arg(step), guide_done_at = sqlc.narg(done_at), guide_skipped = sqlc.arg(skipped)
WHERE id = sqlc.arg(id) AND guide_step = sqlc.arg(from_step) AND guide_done_at IS NULL
RETURNING *;

-- A lord's lifetime count of one deed, for the guide's steps.
-- name: LifeDeed :one
SELECT coalesce(sum(value), 0)::bigint FROM app.player_deeds
WHERE player_id = sqlc.arg(player_id) AND scope = 'life' AND deed = sqlc.arg(deed);

-- name: CountHeroEquipped :one
SELECT count(*)::bigint FROM app.player_items WHERE player_id = $1 AND equipped_on_hero;

-- Lords away long enough for a welcome back, whose last one did not answer
-- this absence (sent before they were last seen) and is past its cooldown --
-- or who were welcomed for this absence and have now been away long enough
-- for the second letter.
-- name: ListWinbackDue :many
SELECT id, last_seen_at, winback_at, winback_tier FROM app.players
WHERE NOT is_bot AND state = 'active'
  AND last_seen_at < sqlc.arg(away_before)::timestamptz
  AND (
        (winback_at IS NULL OR (winback_at < last_seen_at AND winback_at < sqlc.arg(cooldown_before)::timestamptz))
     OR (winback_tier = 1 AND winback_at >= last_seen_at AND last_seen_at < sqlc.arg(long_before)::timestamptz)
  )
ORDER BY last_seen_at
LIMIT sqlc.arg(max_rows);

-- Records the letter sent, pinned to what the job read, so two runs send one.
-- name: MarkWinback :one
UPDATE app.players
SET winback_at = sqlc.arg(at), winback_tier = sqlc.arg(tier)
WHERE id = sqlc.arg(id) AND winback_tier = sqlc.arg(from_tier)
  AND winback_at IS NOT DISTINCT FROM sqlc.narg(from_at)::timestamptz
RETURNING id;

-- A flask drunk: the lord's own sequenced action, so it moves action_seq like
-- any other the client predicts.
-- name: DrinkFlask :one
UPDATE app.players
SET energy_milli = sqlc.arg(energy_milli), energy_updated_at = sqlc.arg(energy_updated_at),
    action_seq = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;
