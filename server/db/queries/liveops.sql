-- Live ops (migration 00042): the hourly event, the calendar's festivals, the
-- season and its Royal Charter, the boards' closes and the deeds.

-- ---------------------------------------------------------------------------
-- The hourly event
-- ---------------------------------------------------------------------------

-- Every hour written down in a window: the rolled, the forced and the skipped.
-- name: ListHourlyEvents :many
SELECT * FROM admin.hourly_events
WHERE hour BETWEEN sqlc.arg(from_hour)::bigint AND sqlc.arg(to_hour)::bigint
ORDER BY hour;

-- An hour's roll, written the first time it is made. A row already there (the
-- panel's, or another server's roll) stands.
-- name: FreezeHourly :exec
INSERT INTO admin.hourly_events (hour, event_id, source)
VALUES (sqlc.arg(hour), sqlc.arg(event_id), 'roll')
ON CONFLICT (hour) DO NOTHING;

-- The panel forces or skips an hour that has not begun.
-- name: SetHourly :one
INSERT INTO admin.hourly_events (hour, event_id, source, set_by, note)
VALUES (sqlc.arg(hour), sqlc.arg(event_id), sqlc.arg(source), sqlc.arg(set_by), sqlc.arg(note))
ON CONFLICT (hour) DO UPDATE
SET event_id = EXCLUDED.event_id, source = EXCLUDED.source, set_by = EXCLUDED.set_by,
    set_at = now(), note = EXCLUDED.note
RETURNING *;

-- Gives a future hour back to the roll.
-- name: ClearHourly :execrows
DELETE FROM admin.hourly_events WHERE hour = sqlc.arg(hour);

-- One use of an hour's event, as long as fewer than max have been taken. No row
-- back means the hour's allowance is spent.
-- name: UseHourly :one
INSERT INTO app.player_hourly (player_id, hour, used)
VALUES (sqlc.arg(player_id), sqlc.arg(hour), 1)
ON CONFLICT (player_id, hour) DO UPDATE SET used = app.player_hourly.used + 1
WHERE app.player_hourly.used < sqlc.arg(max)::smallint
RETURNING used;

-- name: GetHourlyUse :one
SELECT used FROM app.player_hourly WHERE player_id = sqlc.arg(player_id) AND hour = sqlc.arg(hour);

-- How many lords used an hour's event: the panel's schedule.
-- name: CountHourlyUses :many
SELECT hour, count(*)::int AS lords FROM app.player_hourly
WHERE hour BETWEEN sqlc.arg(from_hour)::bigint AND sqlc.arg(to_hour)::bigint
GROUP BY hour;

-- name: PurgeHourlyUse :execrows
DELETE FROM app.player_hourly WHERE hour < sqlc.arg(before_hour)::bigint;

-- ---------------------------------------------------------------------------
-- Festivals
-- ---------------------------------------------------------------------------

-- name: InsertLiveEvent :one
INSERT INTO admin.live_events (template_id, starts_at, ends_at, frozen, note, created_by)
VALUES (sqlc.arg(template_id), sqlc.arg(starts_at), sqlc.arg(ends_at), sqlc.arg(frozen),
        sqlc.arg(note), sqlc.arg(created_by))
RETURNING *;

-- Festivals that would share any moment with a window.
-- name: CountOverlappingEvents :one
SELECT count(*)::int FROM admin.live_events
WHERE revoked_at IS NULL AND starts_at < sqlc.arg(ends_at) AND ends_at > sqlc.arg(starts_at);

-- name: ListLiveEvents :many
SELECT e.*,
       (SELECT count(*) FROM app.player_event pe WHERE pe.event_id = e.id)::int AS lords
FROM admin.live_events e
ORDER BY e.starts_at DESC
LIMIT sqlc.arg(lim);

-- What is running or announced: the poll's read.
-- name: CurrentEvents :many
SELECT * FROM admin.live_events
WHERE revoked_at IS NULL AND ends_at > sqlc.arg(now) AND starts_at < sqlc.arg(until)
ORDER BY starts_at;

-- Festivals a lord took part in, newest first: the Events page's past cards.
-- name: RecentEventsFor :many
SELECT e.*, coalesce(pe.points_milli, 0)::bigint AS my_points_milli
FROM admin.live_events e
LEFT JOIN app.player_event pe ON pe.event_id = e.id AND pe.player_id = sqlc.arg(player_id)
WHERE e.revoked_at IS NULL AND e.ends_at <= sqlc.arg(now) AND e.ends_at > sqlc.arg(since)
ORDER BY e.ends_at DESC
LIMIT 3;

-- name: GetLiveEvent :one
SELECT * FROM admin.live_events WHERE id = sqlc.arg(id);

-- name: RevokeLiveEvent :one
UPDATE admin.live_events SET revoked_at = sqlc.arg(at), revoked_by = sqlc.arg(by)
WHERE id = sqlc.arg(id) AND revoked_at IS NULL AND settled_at IS NULL
RETURNING *;

-- Festivals over and not yet closed.
-- name: EventsToSettle :many
SELECT * FROM admin.live_events
WHERE revoked_at IS NULL AND settled_at IS NULL AND ends_at <= sqlc.arg(now)
ORDER BY ends_at;

-- name: MarkEventSettled :exec
UPDATE admin.live_events SET settled_at = sqlc.arg(at) WHERE id = sqlc.arg(id);

-- Points for one action, under the festival day's cap. Only what the day still
-- has room for is added; a cap lowered mid-day never takes points back.
-- name: AddEventPoints :exec
INSERT INTO app.player_event (player_id, event_id, points_milli, day, day_milli, points_at)
VALUES (sqlc.arg(player_id), sqlc.arg(event_id), LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint),
        sqlc.arg(day)::smallint, LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint), sqlc.arg(now))
ON CONFLICT (player_id, event_id) DO UPDATE
SET points_milli = app.player_event.points_milli + CASE
        WHEN app.player_event.day = EXCLUDED.day
        THEN GREATEST(0, LEAST(app.player_event.day_milli + sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) - app.player_event.day_milli)
        ELSE LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) END,
    day_milli = CASE
        WHEN app.player_event.day = EXCLUDED.day
        THEN GREATEST(app.player_event.day_milli, LEAST(app.player_event.day_milli + sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint))
        ELSE LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) END,
    day = EXCLUDED.day,
    points_at = CASE
        WHEN app.player_event.day = EXCLUDED.day AND app.player_event.day_milli >= sqlc.arg(cap)::bigint
        THEN app.player_event.points_at ELSE EXCLUDED.points_at END;

-- name: GetPlayerEvent :one
SELECT * FROM app.player_event WHERE player_id = sqlc.arg(player_id) AND event_id = sqlc.arg(event_id);

-- name: EnsurePlayerEvent :one
INSERT INTO app.player_event (player_id, event_id) VALUES (sqlc.arg(player_id), sqlc.arg(event_id))
ON CONFLICT (player_id, event_id) DO UPDATE SET tasks = app.player_event.tasks
RETURNING *;

-- Setting the bits is the claim; zero rows means one was already set.
-- name: ClaimEventRewards :one
UPDATE app.player_event
SET tasks = tasks | sqlc.arg(tasks)::int, milestones = milestones | sqlc.arg(milestones)::int
WHERE player_id = sqlc.arg(player_id) AND event_id = sqlc.arg(event_id)
  AND tasks & sqlc.arg(tasks)::int = 0 AND milestones & sqlc.arg(milestones)::int = 0
RETURNING *;

-- A festival's board: first by points, then by who reached them first.
-- name: EventBoard :many
SELECT pe.player_id, pe.points_milli, p.display_name, p.avatar, p.level,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.player_event pe
JOIN app.players p ON p.id = pe.player_id
WHERE pe.event_id = sqlc.arg(event_id) AND pe.points_milli > 0 AND p.state = 'active' AND NOT p.is_bot
ORDER BY pe.points_milli DESC, pe.points_at, pe.player_id
LIMIT sqlc.arg(lim);

-- A lord's place: one more than those ahead of them.
-- name: EventPlace :one
SELECT (count(*) + 1)::int FROM app.player_event pe
JOIN app.players p ON p.id = pe.player_id
WHERE pe.event_id = sqlc.arg(event_id) AND p.state = 'active' AND NOT p.is_bot AND pe.points_milli > 0
  AND (pe.points_milli > sqlc.arg(points_milli)::bigint
       OR (pe.points_milli = sqlc.arg(points_milli)::bigint AND pe.points_at < sqlc.arg(points_at)::timestamptz));

-- name: CountEventLords :one
SELECT count(*)::int FROM app.player_event WHERE event_id = sqlc.arg(event_id) AND points_milli > 0;

-- Every lord's deeds in a festival, for its close.
-- name: EventDeeds :many
SELECT player_id, deed, value FROM app.player_deeds WHERE scope = 'event' AND period = sqlc.arg(event_id);

-- Everyone in a closing festival, in board order: the close pays places and
-- sends what each left unclaimed.
-- name: EventStandings :many
SELECT pe.*, p.is_bot, p.state
FROM app.player_event pe
JOIN app.players p ON p.id = pe.player_id
WHERE pe.event_id = sqlc.arg(event_id)
ORDER BY pe.points_milli DESC, pe.points_at, pe.player_id;

-- ---------------------------------------------------------------------------
-- The season
-- ---------------------------------------------------------------------------

-- Charter points for one action, under the season day's cap (as AddEventPoints).
-- The row's might_start is the lord's Might when the row is first written,
-- and never moves after.
-- name: AddSeasonPoints :exec
INSERT INTO app.player_season (player_id, season, points_milli, day, day_milli, points_at, might_start)
VALUES (sqlc.arg(player_id), sqlc.arg(season), LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint),
        sqlc.arg(day)::smallint, LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint), sqlc.arg(now),
        sqlc.arg(might)::bigint)
ON CONFLICT (player_id, season) DO UPDATE
SET points_milli = app.player_season.points_milli + CASE
        WHEN app.player_season.day = EXCLUDED.day
        THEN GREATEST(0, LEAST(app.player_season.day_milli + sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) - app.player_season.day_milli)
        ELSE LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) END,
    day_milli = CASE
        WHEN app.player_season.day = EXCLUDED.day
        THEN GREATEST(app.player_season.day_milli, LEAST(app.player_season.day_milli + sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint))
        ELSE LEAST(sqlc.arg(add)::bigint, sqlc.arg(cap)::bigint) END,
    day = EXCLUDED.day,
    points_at = CASE
        WHEN app.player_season.day = EXCLUDED.day AND app.player_season.day_milli >= sqlc.arg(cap)::bigint
        THEN app.player_season.points_at ELSE EXCLUDED.points_at END;

-- name: GetPlayerSeason :one
SELECT * FROM app.player_season WHERE player_id = sqlc.arg(player_id) AND season = sqlc.arg(season);

-- name: EnsurePlayerSeason :one
INSERT INTO app.player_season (player_id, season, might_start)
VALUES (sqlc.arg(player_id), sqlc.arg(season), sqlc.arg(might)::bigint)
ON CONFLICT (player_id, season) DO UPDATE SET free_claimed = app.player_season.free_claimed
RETURNING *;

-- Setting the bits is the claim; zero rows means one was already set.
-- name: ClaimSeasonTiers :one
UPDATE app.player_season
SET free_claimed = free_claimed | sqlc.arg(free)::bigint, royal_claimed = royal_claimed | sqlc.arg(royal)::bigint
WHERE player_id = sqlc.arg(player_id) AND season = sqlc.arg(season)
  AND free_claimed & sqlc.arg(free)::bigint = 0 AND royal_claimed & sqlc.arg(royal)::bigint = 0
RETURNING *;

-- Opens the royal lane for a season, once.
-- name: UnlockRoyal :one
UPDATE app.player_season SET royal_at = sqlc.arg(at), royal_ref = sqlc.narg(ref)
WHERE player_id = sqlc.arg(player_id) AND season = sqlc.arg(season) AND royal_at IS NULL
RETURNING *;

-- A refunded Charter closes the lane it opened, and forgets what was claimed
-- from it (the refund takes that back): the tiers it had claimed come back, so
-- their tokens can be counted off.
-- name: RevokeRoyal :one
WITH old AS (
    SELECT season, royal_claimed FROM app.player_season
    WHERE player_id = sqlc.arg(player_id) AND royal_ref = sqlc.arg(ref)::text
    FOR UPDATE
)
UPDATE app.player_season ps SET royal_at = NULL, royal_ref = NULL, royal_claimed = 0
FROM old
WHERE ps.player_id = sqlc.arg(player_id) AND ps.season = old.season
RETURNING ps.season, old.royal_claimed AS was_claimed;

-- A season's board by renown (its Charter points), first there first placed.
-- name: SeasonBoard :many
SELECT ps.player_id, ps.points_milli, p.display_name, p.avatar, p.level,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.player_season ps
JOIN app.players p ON p.id = ps.player_id
WHERE ps.season = sqlc.arg(season) AND ps.points_milli > 0 AND p.state = 'active' AND NOT p.is_bot
ORDER BY ps.points_milli DESC, ps.points_at, ps.player_id
LIMIT sqlc.arg(lim);

-- Every lord with renown in a season, in place order, for its close.
-- name: SeasonStandings :many
SELECT ps.*
FROM app.player_season ps
JOIN app.players p ON p.id = ps.player_id
WHERE ps.season = sqlc.arg(season) AND ps.points_milli > 0 AND p.state = 'active' AND NOT p.is_bot
ORDER BY ps.points_milli DESC, ps.points_at, ps.player_id;

-- Every row of a season, for what its lords left unclaimed.
-- name: SeasonRows :many
SELECT * FROM app.player_season WHERE season = sqlc.arg(season) AND points_milli > 0;

-- The panel's view of a season.
-- name: SeasonSummary :one
SELECT count(*)::int AS lords,
       count(*) FILTER (WHERE royal_at IS NOT NULL)::int AS royal,
       count(*) FILTER (WHERE royal_ref IS NOT NULL)::int AS royal_bought,
       coalesce(sum(points_milli), 0)::bigint AS points_milli,
       coalesce(max(points_milli), 0)::bigint AS top_milli
FROM app.player_season WHERE season = sqlc.arg(season);

-- How the season's lords spread over its tiers, a band of ten at a time.
-- name: SeasonTierBands :many
SELECT LEAST(sqlc.arg(tiers)::int, (points_milli / 1000 / sqlc.arg(per_tier)::bigint)::int) / 10 AS band,
       count(*)::int AS lords
FROM app.player_season WHERE season = sqlc.arg(season)
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- Boards and their closes
-- ---------------------------------------------------------------------------

-- A board of one deed over one period (a week, a season): lords level with
-- each other share a place, and the order among them is fixed by id.
-- name: FillDeedBoard :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT sqlc.arg(board)::text, row_number() OVER w, rank() OVER (ORDER BY d.value DESC), d.player_id, d.value
FROM app.player_deeds d
JOIN app.players p ON p.id = d.player_id
WHERE d.scope = sqlc.arg(scope) AND d.period = sqlc.arg(period) AND d.deed = sqlc.arg(deed)
  AND d.value > 0 AND p.state = 'active' AND NOT p.is_bot
WINDOW w AS (ORDER BY d.value DESC, d.player_id)
ORDER BY d.value DESC, d.player_id
LIMIT sqlc.arg(lim);

-- The season's renown, a place each: whoever reached their points first.
-- name: FillRenownBoard :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT sqlc.arg(board)::text, row_number() OVER w, row_number() OVER w, ps.player_id, ps.points_milli / 1000
FROM app.player_season ps
JOIN app.players p ON p.id = ps.player_id
WHERE ps.season = sqlc.arg(season) AND ps.points_milli > 0 AND p.state = 'active' AND NOT p.is_bot
WINDOW w AS (ORDER BY ps.points_milli DESC, ps.points_at, ps.player_id)
ORDER BY ps.points_milli DESC, ps.points_at, ps.player_id
LIMIT sqlc.arg(lim);

-- The Might a season's lords have gained since their first deed in it (the
-- army's cached Might, as the Might board reads it); level lords share a place.
-- name: FillMightGainBoard :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT sqlc.arg(board)::text, row_number() OVER w, rank() OVER (ORDER BY p.might - ps.might_start DESC),
       ps.player_id, p.might - ps.might_start
FROM app.player_season ps
JOIN app.players p ON p.id = ps.player_id
WHERE ps.season = sqlc.arg(season) AND ps.might_start IS NOT NULL AND p.might > ps.might_start
  AND p.state = 'active' AND NOT p.is_bot
WINDOW w AS (ORDER BY p.might - ps.might_start DESC, ps.player_id)
ORDER BY p.might - ps.might_start DESC, ps.player_id
LIMIT sqlc.arg(lim);

-- A closed season's places on the Might gained, as far as its rewards reach.
-- name: MightGainStandings :many
SELECT player_id, value, place FROM (
    SELECT ps.player_id, (p.might - ps.might_start)::bigint AS value,
           rank() OVER (ORDER BY p.might - ps.might_start DESC)::int AS place
    FROM app.player_season ps
    JOIN app.players p ON p.id = ps.player_id
    WHERE ps.season = sqlc.arg(season) AND ps.might_start IS NOT NULL AND p.might > ps.might_start
      AND p.state = 'active' AND NOT p.is_bot
) ranked
WHERE place <= sqlc.arg(lim)::int
ORDER BY place, player_id;

-- A closed period's places on a deed's board, as far as its rewards reach.
-- name: DeedStandings :many
SELECT player_id, value, place FROM (
    SELECT d.player_id, d.value, rank() OVER (ORDER BY d.value DESC)::int AS place
    FROM app.player_deeds d
    JOIN app.players p ON p.id = d.player_id
    WHERE d.scope = sqlc.arg(scope) AND d.period = sqlc.arg(period) AND d.deed = sqlc.arg(deed)
      AND d.value > 0 AND p.state = 'active' AND NOT p.is_bot
) ranked
WHERE place <= sqlc.arg(lim)::int
ORDER BY place, player_id;

-- name: PeriodClosed :one
SELECT EXISTS (SELECT 1 FROM admin.period_closes WHERE what = sqlc.arg(what) AND period = sqlc.arg(period));

-- name: ClosePeriod :exec
INSERT INTO admin.period_closes (what, period, lords) VALUES (sqlc.arg(what), sqlc.arg(period), sqlc.arg(lords))
ON CONFLICT (what, period) DO NOTHING;

-- name: ListPeriodCloses :many
SELECT * FROM admin.period_closes ORDER BY closed_at DESC LIMIT sqlc.arg(lim);

-- ---------------------------------------------------------------------------
-- The deeds (achievements)
-- ---------------------------------------------------------------------------

-- name: ListAchievementClaims :many
SELECT achievement, claimed FROM app.player_achievements WHERE player_id = sqlc.arg(player_id);

-- Moves a deed's claimed tiers from what the caller read to what it pays.
-- name: ClaimAchievement :one
INSERT INTO app.player_achievements (player_id, achievement, claimed)
VALUES (sqlc.arg(player_id), sqlc.arg(achievement), sqlc.arg(to_tier)::smallint)
ON CONFLICT (player_id, achievement) DO UPDATE
SET claimed = EXCLUDED.claimed, claimed_at = now()
WHERE app.player_achievements.claimed = sqlc.arg(from_tier)::smallint
RETURNING claimed;

-- Jobs a lord has worked to their last mastery milestone.
-- name: CountMastered :one
SELECT count(*)::int FROM app.player_job_progress
WHERE player_id = sqlc.arg(player_id) AND collects >= sqlc.arg(collects)::bigint;

-- name: CountCollection :one
SELECT count(*)::int FROM app.player_collection WHERE player_id = sqlc.arg(player_id);

-- The lifetime counters, raised to what the records kept before the counters
-- began (Wave 0) show. GREATEST, never a sum: a record since then is already
-- counted, and the backfill may run again safely. (Energy is priced by the
-- balance's jobs, so it is summed in Go: JobCollects, RaiseLifeDeeds.)
-- name: BackfillLifeDeeds :execrows
INSERT INTO app.player_deeds (player_id, scope, period, deed, value)
SELECT player_id, 'life', 0, deed, value FROM (
    SELECT attacker_id AS player_id, 'raids' AS deed, count(*)::bigint AS value
      FROM app.battles GROUP BY attacker_id
    UNION ALL
    SELECT attacker_id, 'raid_wins', count(*)::bigint FROM app.battles WHERE attacker_won GROUP BY attacker_id
    UNION ALL
    SELECT attacker_id, 'gold_stolen', sum(gold_stolen)::bigint FROM app.battles
      WHERE attacker_won GROUP BY attacker_id HAVING sum(gold_stolen) > 0
    UNION ALL
    SELECT defender_id, 'defenses_held', count(*)::bigint FROM app.battles WHERE NOT attacker_won GROUP BY defender_id
    UNION ALL
    SELECT player_id, 'collects', sum(collects)::bigint FROM app.player_job_progress
      GROUP BY player_id HAVING sum(collects) > 0
    UNION ALL
    SELECT player_id, 'upgrades', sum(level)::bigint FROM app.player_upgrades
      GROUP BY player_id HAVING sum(level) > 0
    UNION ALL
    SELECT player_id, 'holdings', sum(level)::bigint FROM app.player_holdings
      GROUP BY player_id HAVING sum(level) > 0
    UNION ALL
    SELECT player_id, 'buys', count(*)::bigint FROM app.gold_ledger WHERE reason = 'shop_buy' GROUP BY player_id
    UNION ALL
    SELECT player_id, 'shop_gold', sum(-delta)::bigint FROM app.gold_ledger
      WHERE reason = 'shop_buy' AND delta < 0 GROUP BY player_id
    UNION ALL
    SELECT player_id, 'sells', count(*)::bigint FROM app.gold_ledger WHERE reason = 'item_sell' GROUP BY player_id
    UNION ALL
    SELECT player_id, 'recruits', count(*)::bigint FROM app.gold_ledger WHERE reason = 'recruit' GROUP BY player_id
    UNION ALL
    SELECT player_id, 'rerolls', count(*)::bigint FROM app.gold_ledger WHERE reason = 'reroll' GROUP BY player_id
    UNION ALL
    SELECT player_id, 'donated_gold', sum(-delta)::bigint FROM app.gold_ledger
      WHERE reason = 'kingdom_donate' AND delta < 0 GROUP BY player_id
    UNION ALL
    SELECT player_id, 'mail_claims', count(*)::bigint FROM app.mail WHERE claimed_at IS NOT NULL GROUP BY player_id
    UNION ALL
    SELECT id, 'daily_claims', (calendar_cycle * 28 + calendar_pos)::bigint FROM app.players
      WHERE NOT is_bot AND calendar_cycle * 28 + calendar_pos > 0
    UNION ALL
    SELECT id, 'carts_opened', carts_opened::bigint FROM app.players WHERE NOT is_bot AND carts_opened > 0
) derived
WHERE value > 0 AND EXISTS (SELECT 1 FROM app.players p WHERE p.id = derived.player_id AND NOT p.is_bot)
ON CONFLICT (player_id, scope, period, deed)
DO UPDATE SET value = GREATEST(app.player_deeds.value, EXCLUDED.value);

-- Every lord's collects per job, for the energy they spent (the job's cost is
-- in the balance).
-- name: JobCollects :many
SELECT jp.player_id, jp.job_id, jp.collects
FROM app.player_job_progress jp
JOIN app.players p ON p.id = jp.player_id
WHERE NOT p.is_bot AND jp.collects > 0;

-- Raises lifetime counters to at least the given values (parallel arrays).
-- name: RaiseLifeDeeds :exec
INSERT INTO app.player_deeds (player_id, scope, period, deed, value)
SELECT unnest(sqlc.arg(player_ids)::uuid[]), 'life', 0, unnest(sqlc.arg(deeds)::text[]), unnest(sqlc.arg(vals)::bigint[])
ON CONFLICT (player_id, scope, period, deed)
DO UPDATE SET value = GREATEST(app.player_deeds.value, EXCLUDED.value);
