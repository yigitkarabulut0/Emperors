-- Rekabet (migration 00044): the Honour Arena's ladder, the Bounty Board's
-- escrow and the Throne a week of war crowns.

-- ---------------------------------------------------------------------------
-- The Honour Arena
-- ---------------------------------------------------------------------------

-- name: GetArena :one
SELECT * FROM app.arena WHERE player_id = sqlc.arg(player_id);

-- Locked in ascending player_id, the order LockTwoPlayers uses, so two lords
-- meeting each other at the same instant cannot deadlock.
-- name: LockArenaRows :many
SELECT * FROM app.arena
WHERE player_id = ANY(sqlc.arg(ids)::uuid[])
ORDER BY player_id
FOR UPDATE;

-- A lord's standing, made if it is missing and rolled if it is a season stale.
-- The half reset happens HERE as well as in the job: whichever runs first, the
-- other is a no-op, and a lord never fights a fresh season on last season's
-- rating.
-- name: UpsertArena :one
INSERT INTO app.arena (player_id, season, rating, peak)
VALUES (sqlc.arg(player_id), sqlc.arg(season), sqlc.arg(start_rating), sqlc.arg(start_rating))
ON CONFLICT (player_id) DO UPDATE
SET season     = EXCLUDED.season,
    rating     = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.rating
                      ELSE GREATEST(sqlc.arg(floor_rating)::int,
                           sqlc.arg(start_rating)::int
                           + ((app.arena.rating - sqlc.arg(start_rating)::int)
                              * sqlc.arg(reset_bp)::int) / 10000) END,
    peak       = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.peak
                      ELSE GREATEST(sqlc.arg(floor_rating)::int,
                           sqlc.arg(start_rating)::int
                           + ((app.arena.rating - sqlc.arg(start_rating)::int)
                              * sqlc.arg(reset_bp)::int) / 10000) END,
    wins       = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.wins ELSE 0 END,
    losses     = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.losses ELSE 0 END,
    streak     = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.streak ELSE 0 END,
    milestones = CASE WHEN app.arena.season = EXCLUDED.season THEN app.arena.milestones ELSE 0 END
RETURNING *;

-- The result of one fight.
-- name: ApplyArenaResult :one
UPDATE app.arena
SET rating     = sqlc.arg(rating),
    peak       = GREATEST(peak, sqlc.arg(rating)),
    wins       = wins + sqlc.arg(won)::int,
    losses     = losses + sqlc.arg(lost)::int,
    streak     = sqlc.arg(streak),
    milestones = sqlc.arg(milestones),
    last_at    = now()
WHERE player_id = sqlc.arg(player_id)
RETURNING *;

-- Spends one of the day's fights and moves the lord's own sequence. The count
-- comes from the row the fight already locked and is written in the same
-- statement, so two taps cannot both be the fifth.
-- name: SpendArenaTicket :one
UPDATE app.players
SET arena_day = sqlc.arg(day), arena_fights_used = sqlc.arg(used), action_seq = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: SpendArenaRefresh :one
UPDATE app.players
SET arena_day = sqlc.arg(day), arena_refresh_used = sqlc.arg(used), action_seq = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Marks the day's first win. Zero rows back means it was already marked, so two
-- wins in one day cannot both be first -- the guard is the WHERE.
-- name: MarkArenaFirstWin :one
UPDATE app.players
SET arena_first_win_on = sqlc.arg(day)
WHERE id = sqlc.arg(id)
  AND (arena_first_win_on IS NULL OR arena_first_win_on < sqlc.arg(day))
RETURNING *;

-- The rivals a lord may be shown: inside the rating band, in the season, not
-- themselves, not a kingdom ally, not a bot, above the level raiding opens at,
-- and not one of their last few arena opponents.
-- name: ArenaOpponents :many
SELECT a.player_id, a.rating, a.wins, a.losses,
       p.display_name, p.avatar, p.level, p.kingdom_id,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.arena a
JOIN app.players p ON p.id = a.player_id
WHERE a.season = sqlc.arg(season)
  AND a.rating BETWEEN sqlc.arg(lo) AND sqlc.arg(hi)
  AND a.player_id <> sqlc.arg(me)
  AND p.state = 'active'
  AND NOT p.is_bot
  AND p.level >= sqlc.arg(fight_at)
  AND (sqlc.narg(kingdom_id)::uuid IS NULL OR p.kingdom_id IS DISTINCT FROM sqlc.narg(kingdom_id)::uuid)
  AND NOT EXISTS (
        SELECT 1 FROM app.battles b
        WHERE b.kind = 'arena' AND b.attacker_id = sqlc.arg(me) AND b.defender_id = a.player_id
          AND b.created_at > now() - make_interval(hours => sqlc.arg(repeat_hours)::int))
ORDER BY abs(a.rating - sqlc.arg(rating)::int), a.player_id
LIMIT sqlc.arg(lim);

-- A lord's place on the ladder. Ties are broken by who reached the rating
-- first, which is how the top league's "and the top fifty" stays decidable.
-- name: ArenaRank :one
SELECT place FROM (
    SELECT player_id, row_number() OVER (ORDER BY rating DESC, last_at, player_id)::int AS place
    FROM app.arena a
    JOIN app.players p ON p.id = a.player_id
    WHERE a.season = sqlc.arg(season) AND p.state = 'active' AND NOT p.is_bot
) ranked
WHERE player_id = sqlc.arg(player_id);

-- The ladder, for the panel.
-- name: ArenaLadder :many
SELECT a.player_id, a.rating, a.peak, a.wins, a.losses,
       p.display_name, p.level,
       row_number() OVER (ORDER BY a.rating DESC, a.last_at, a.player_id)::int AS place
FROM app.arena a
JOIN app.players p ON p.id = a.player_id
WHERE a.season = sqlc.arg(season) AND p.state = 'active' AND NOT p.is_bot
ORDER BY a.rating DESC, a.last_at, a.player_id
LIMIT sqlc.arg(lim);

-- The season's arena board, filled beside the others by RefreshLeaderboards.
-- The PEAK, not the wins: the ladder is what the arena measures, and wins alone
-- would pay whoever spent the most tickets.
-- name: FillArenaBoard :exec
INSERT INTO app.leaderboard_entries (board, rank, place, player_id, value)
SELECT sqlc.arg(board)::text, row_number() OVER w, row_number() OVER w, a.player_id, a.peak
FROM app.arena a
JOIN app.players p ON p.id = a.player_id
WHERE a.season = sqlc.arg(season) AND p.state = 'active' AND NOT p.is_bot
WINDOW w AS (ORDER BY a.peak DESC, a.last_at, a.player_id)
ORDER BY a.peak DESC, a.last_at, a.player_id
LIMIT sqlc.arg(lim);

-- A closed season's arena places, as far as the board pays.
-- name: ArenaStandings :many
SELECT player_id, value, place FROM (
    SELECT a.player_id, a.peak AS value,
           rank() OVER (ORDER BY a.peak DESC)::int AS place
    FROM app.arena a
    JOIN app.players p ON p.id = a.player_id
    WHERE a.season = sqlc.arg(season) AND p.state = 'active' AND NOT p.is_bot
) ranked
WHERE place <= sqlc.arg(lim)::int
ORDER BY place, player_id;

-- The bulk half of the season roll. A row already rolled (lazily, by
-- UpsertArena) has the new season and is skipped.
-- name: HalfResetArena :execrows
UPDATE app.arena
SET season     = sqlc.arg(season),
    rating     = GREATEST(sqlc.arg(floor_rating)::int,
                 sqlc.arg(start_rating)::int
                 + ((rating - sqlc.arg(start_rating)::int) * sqlc.arg(reset_bp)::int) / 10000),
    peak       = GREATEST(sqlc.arg(floor_rating)::int,
                 sqlc.arg(start_rating)::int
                 + ((rating - sqlc.arg(start_rating)::int) * sqlc.arg(reset_bp)::int) / 10000),
    wins = 0, losses = 0, streak = 0, milestones = 0
WHERE season < sqlc.arg(season);

-- ---------------------------------------------------------------------------
-- The Bounty Board
-- ---------------------------------------------------------------------------

-- Takes the escrow and the fee from the purse and moves the lord's sequence.
-- Affordability is the WHERE: zero rows back is "not enough gold", and no
-- amount of concurrency can spend the same coin twice.
-- name: PayForBounty :one
UPDATE app.players
SET gold = gold - sqlc.arg(total), action_seq = sqlc.arg(action_seq),
    bounty_day = sqlc.arg(day), bounty_placed = sqlc.arg(placed)
WHERE id = sqlc.arg(id) AND gold >= sqlc.arg(total)
RETURNING *;

-- name: InsertBounty :one
INSERT INTO app.bounties (id, target_id, placed_by, amount, remaining, fee_burned, plate, expires_at)
VALUES (sqlc.arg(id), sqlc.arg(target_id), sqlc.arg(placed_by), sqlc.arg(amount),
        sqlc.arg(amount), sqlc.arg(fee_burned), sqlc.arg(plate), sqlc.arg(expires_at))
RETURNING *;

-- name: GetBounty :one
SELECT * FROM app.bounties WHERE id = sqlc.arg(id);

-- name: LockBounty :one
SELECT * FROM app.bounties WHERE id = sqlc.arg(id) FOR UPDATE;

-- The board this lord may hunt. Every leash that can be a filter IS one, so a
-- card the server would refuse is never drawn.
-- name: ListOpenBounties :many
SELECT b.*, p.display_name, p.avatar, p.level, p.shield_until,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.bounties b
JOIN app.players p ON p.id = b.target_id
WHERE b.closed_at IS NULL
  AND b.expires_at > now()
  AND b.target_id <> sqlc.arg(me)
  AND b.placed_by <> sqlc.arg(me)
  AND p.state = 'active'
  AND NOT p.is_bot
  AND p.level >= sqlc.arg(min_level)
  AND (sqlc.narg(kingdom_id)::uuid IS NULL OR p.kingdom_id IS DISTINCT FROM sqlc.narg(kingdom_id)::uuid)
ORDER BY b.remaining DESC, b.placed_at
LIMIT sqlc.arg(lim);

-- What stands on this lord's own head, and what they have placed.
-- name: ListBountiesOnMe :many
SELECT b.*, p.display_name AS placer_name
FROM app.bounties b
JOIN app.players p ON p.id = b.placed_by
WHERE b.target_id = sqlc.arg(me) AND b.closed_at IS NULL AND b.expires_at > now()
ORDER BY b.remaining DESC, b.placed_at
LIMIT sqlc.arg(lim);

-- name: ListMyBounties :many
SELECT b.*, p.display_name AS target_name, p.avatar AS target_avatar, p.level AS target_level
FROM app.bounties b
JOIN app.players p ON p.id = b.target_id
WHERE b.placed_by = sqlc.arg(me)
ORDER BY (b.closed_at IS NOT NULL), b.placed_at DESC
LIMIT sqlc.arg(lim);

-- name: CountOpenBountiesOnMe :one
SELECT count(*)::int FROM app.bounties
WHERE target_id = sqlc.arg(me) AND closed_at IS NULL AND expires_at > now();

-- name: CountOpenBountiesOn :one
SELECT count(*)::int FROM app.bounties
WHERE target_id = sqlc.arg(target_id) AND closed_at IS NULL AND expires_at > now();

-- Draws a claim out of the escrow, and closes the bounty when it is empty.
-- Zero rows back is the race lost -- somebody else drew it, or it expired
-- between the read and the write -- and the caller answers ErrBountyGone. The
-- guard cannot be raced because it IS the WHERE.
-- name: DrawBounty :one
UPDATE app.bounties
SET remaining = remaining - sqlc.arg(pay),
    closed_at = CASE WHEN remaining - sqlc.arg(pay) <= 0 THEN now() END,
    closed_as = CASE WHEN remaining - sqlc.arg(pay) <= 0 THEN 'claimed' END
WHERE id = sqlc.arg(id) AND closed_at IS NULL AND expires_at > now() AND remaining >= sqlc.arg(pay)
RETURNING *;

-- name: InsertBountyClaim :one
INSERT INTO app.bounty_claims (bounty_id, battle_id, claimer_id, target_id, placer_id, paid, uweek)
VALUES (sqlc.arg(bounty_id), sqlc.arg(battle_id), sqlc.arg(claimer_id), sqlc.arg(target_id),
        sqlc.arg(placer_id), sqlc.arg(paid), sqlc.arg(uweek))
RETURNING *;

-- The pair's cap: the same placer and claimer at most so many times a week.
-- name: CountPairClaimsThisWeek :one
SELECT count(*)::int FROM app.bounty_claims
WHERE placer_id = sqlc.arg(placer_id) AND claimer_id = sqlc.arg(claimer_id)
  AND uweek = sqlc.arg(uweek);

-- name: ExpireBounties :many
SELECT * FROM app.bounties
WHERE closed_at IS NULL AND expires_at <= sqlc.arg(now)::timestamptz
ORDER BY expires_at
LIMIT sqlc.arg(lim);

-- name: CloseBounty :one
UPDATE app.bounties
SET closed_at = now(), closed_as = sqlc.arg(closed_as), remaining = 0
WHERE id = sqlc.arg(id) AND closed_at IS NULL
RETURNING *;

-- Gives a purse back WITHOUT moving the lord's sequence.
--
-- CreditGold writes action_seq, and a job must never move the number the
-- client's queued collects are counting on. This is the ApplyBattleDefender
-- shape, and it is the reason this query exists at all.
-- name: RefundBounty :one
UPDATE app.players SET gold = gold + sqlc.arg(gold)
WHERE id = sqlc.arg(id)
RETURNING *;

-- What the board has burned and holds, for the panel.
-- name: BountyTotals :one
SELECT coalesce(sum(fee_burned) FILTER (WHERE placed_at > sqlc.arg(since)::timestamptz), 0)::bigint AS burned,
       coalesce(sum(remaining) FILTER (WHERE closed_at IS NULL), 0)::bigint           AS escrowed,
       count(*) FILTER (WHERE closed_at IS NULL)::int                                  AS open,
       count(*) FILTER (WHERE closed_as = 'claimed' AND closed_at > sqlc.arg(since)::timestamptz)::int AS claimed
FROM app.bounties;

-- ---------------------------------------------------------------------------
-- The Throne
-- ---------------------------------------------------------------------------

-- Renown gained in a UTC week, by kingdom. Written by awardReputation, the one
-- place kingdom renown is minted.
-- name: BumpKingdomWeek :exec
INSERT INTO app.kingdom_week (kingdom_id, uweek, reputation)
VALUES (sqlc.arg(kingdom_id), sqlc.arg(uweek), sqlc.arg(reputation))
ON CONFLICT (kingdom_id, uweek) DO UPDATE
SET reputation = app.kingdom_week.reputation + EXCLUDED.reputation;

-- The week's race, on the measure the Throne is decided by (week_gain).
-- Kingdoms under min_members are not candidates and are not shown.
-- name: ThroneRaceByWeekGain :many
SELECT k.id AS kingdom_id, k.name, k.tag,
       coalesce(w.reputation, 0)::bigint AS reputation,
       (SELECT count(*) FROM app.players m
        WHERE m.kingdom_id = k.id AND m.state = 'active')::int AS members,
       (SELECT m.id FROM app.players m
        WHERE m.kingdom_id = k.id AND m.kingdom_role = 'king' LIMIT 1) AS king_id
FROM app.kingdoms k
LEFT JOIN app.kingdom_week w ON w.kingdom_id = k.id AND w.uweek = sqlc.arg(uweek)
WHERE (SELECT count(*) FROM app.players m
       WHERE m.kingdom_id = k.id AND m.state = 'active') >= sqlc.arg(min_members)::int
ORDER BY coalesce(w.reputation, 0) DESC, k.created_at, k.id
LIMIT sqlc.arg(lim);

-- The same race on the cumulative measure (total), the alternative the balance
-- can switch to.
-- name: ThroneRaceByTotal :many
SELECT k.id AS kingdom_id, k.name, k.tag,
       k.reputation::bigint AS reputation,
       (SELECT count(*) FROM app.players m
        WHERE m.kingdom_id = k.id AND m.state = 'active')::int AS members,
       (SELECT m.id FROM app.players m
        WHERE m.kingdom_id = k.id AND m.kingdom_role = 'king' LIMIT 1) AS king_id
FROM app.kingdoms k
WHERE (SELECT count(*) FROM app.players m
       WHERE m.kingdom_id = k.id AND m.state = 'active') >= sqlc.arg(min_members)::int
ORDER BY k.reputation DESC, k.created_at, k.id
LIMIT sqlc.arg(lim);

-- Crowns a week's emperor. Nothing back means the week was already settled --
-- the primary key IS the idempotence, so no job has to remember it ran.
-- name: CrownEmperor :one
INSERT INTO app.throne (uweek, kingdom_id, emperor_id, reputation, members, reign_ends)
VALUES (sqlc.arg(uweek), sqlc.arg(kingdom_id), sqlc.arg(emperor_id), sqlc.arg(reputation),
        sqlc.arg(members), sqlc.arg(reign_ends))
ON CONFLICT (uweek) DO NOTHING
RETURNING *;

-- name: CurrentThrone :one
SELECT t.*, k.name AS kingdom_name, k.tag AS kingdom_tag,
       p.display_name AS emperor_name, p.avatar AS emperor_avatar,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.throne t
JOIN app.kingdoms k ON k.id = t.kingdom_id
JOIN app.players p ON p.id = t.emperor_id
WHERE t.crowned_at <= sqlc.arg(now)::timestamptz AND t.reign_ends > sqlc.arg(now)::timestamptz
ORDER BY t.uweek DESC
LIMIT 1;

-- The reign in force, with only what the boost poll needs.
-- name: ActiveDecree :one
SELECT t.uweek, t.kingdom_id, t.emperor_id, t.decree_id, t.decree_ends,
       k.name AS kingdom_name, p.display_name AS emperor_name
FROM app.throne t
JOIN app.kingdoms k ON k.id = t.kingdom_id
JOIN app.players p ON p.id = t.emperor_id
WHERE t.decree_id IS NOT NULL AND t.decree_ends > sqlc.arg(now)::timestamptz
ORDER BY t.decree_ends DESC
LIMIT 1;

-- name: ListThrones :many
SELECT t.*, k.name AS kingdom_name, k.tag AS kingdom_tag,
       p.display_name AS emperor_name
FROM app.throne t
JOIN app.kingdoms k ON k.id = t.kingdom_id
JOIN app.players p ON p.id = t.emperor_id
ORDER BY t.uweek DESC
LIMIT sqlc.arg(lim);

-- The reign's one edict. Once, by the emperor, inside the reign: all four
-- guards are the WHERE, so no read-then-write race can declare twice.
-- name: DeclareDecree :one
UPDATE app.throne
SET decree_id = sqlc.arg(decree_id)::text, decree_at = sqlc.arg(now)::timestamptz, decree_ends = sqlc.arg(ends)::timestamptz
WHERE uweek = sqlc.arg(uweek) AND emperor_id = sqlc.arg(emperor_id)
  AND decree_id IS NULL AND reign_ends > sqlc.arg(now)::timestamptz
RETURNING *;

-- The emperor's court, ordered, so a crowning that resumes letters the same
-- lords in the same order.
-- name: ListCourt :many
SELECT id, display_name FROM app.players
WHERE kingdom_id = sqlc.arg(kingdom_id)::uuid AND state = 'active' AND NOT is_bot
ORDER BY id;

-- Keeps a season of weeks; older ones are only of interest to a historian.
-- name: PurgeKingdomWeeks :exec
DELETE FROM app.kingdom_week WHERE uweek < sqlc.arg(before);

-- ---------------------------------------------------------------------------
-- The desk (service/pvp_desk.go)
-- ---------------------------------------------------------------------------

-- name: CountArenaSince :one
SELECT count(*)::int AS fights,
       count(*) FILTER (WHERE attacker_id = defender_id)::int AS champions
FROM app.battles
WHERE kind = 'arena' AND created_at > sqlc.arg(since)::timestamptz;

-- name: ListBountiesDesk :many
SELECT b.*, t.display_name AS target_name, p.display_name AS placer_name
FROM app.bounties b
JOIN app.players t ON t.id = b.target_id
JOIN app.players p ON p.id = b.placed_by
ORDER BY (b.closed_at IS NOT NULL), b.placed_at DESC
LIMIT sqlc.arg(lim);

-- Placers and claimers who keep meeting: the shape collusion takes.
-- name: BountyPairs :many
SELECT p.display_name AS placer_name, c.display_name AS claimer_name,
       count(*)::int AS claims, coalesce(sum(bc.paid), 0)::bigint AS paid
FROM app.bounty_claims bc
JOIN app.players p ON p.id = bc.placer_id
JOIN app.players c ON c.id = bc.claimer_id
WHERE bc.uweek = sqlc.arg(uweek)
GROUP BY p.display_name, c.display_name
HAVING count(*) > 1
ORDER BY count(*) DESC, sum(bc.paid) DESC
LIMIT sqlc.arg(lim);
