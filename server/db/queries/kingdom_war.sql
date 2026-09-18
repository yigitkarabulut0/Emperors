-- Dalga 8 (migration 00048): the kingdom's boss and its wars.

-- ---------------------------------------------------------------------------
-- The boss
-- ---------------------------------------------------------------------------

-- The beast standing against this kingdom, if one is.
-- name: GetKingdomBoss :one
SELECT * FROM app.kingdom_bosses
WHERE kingdom_id = sqlc.arg(kingdom_id) AND settled_at IS NULL;

-- The same, locked, for the blow that is about to land on it.
-- name: LockKingdomBoss :one
SELECT * FROM app.kingdom_bosses
WHERE id = sqlc.arg(id) AND settled_at IS NULL
FOR UPDATE;

-- A beast rises. The unique index is the rule that there is only ever one:
-- nothing comes back when a kingdom already has one standing.
-- name: RaiseBoss :one
INSERT INTO app.kingdom_bosses (kingdom_id, boss_id, level, hp_max, hp_left,
                                kingdom_might, members, started_at, ends_at,
                                rolled_config_version)
VALUES (sqlc.arg(kingdom_id), sqlc.arg(boss_id), sqlc.arg(level), sqlc.arg(hp_max),
        sqlc.arg(hp_max), sqlc.arg(kingdom_might), sqlc.arg(members), sqlc.arg(now),
        sqlc.arg(ends_at), sqlc.arg(config_version))
ON CONFLICT DO NOTHING
RETURNING *;

-- A blow lands. The WHERE is the guard: a beast already down takes nothing more,
-- and two lords striking at once cannot take it past zero between them.
-- name: WoundBoss :one
UPDATE app.kingdom_bosses
SET hp_left = GREATEST(0, hp_left - sqlc.arg(damage)),
    killed_at = CASE WHEN hp_left - sqlc.arg(damage) <= 0 AND killed_at IS NULL
                     THEN sqlc.arg(now) ELSE killed_at END,
    killed_by = CASE WHEN hp_left - sqlc.arg(damage) <= 0 AND killed_by IS NULL
                     THEN sqlc.arg(player_id) ELSE killed_by END
WHERE id = sqlc.arg(id) AND settled_at IS NULL
RETURNING *;

-- How many times this kingdom has put one down: what the next beast's level is.
-- name: CountBossKills :one
SELECT count(*) FROM app.kingdom_bosses
WHERE kingdom_id = sqlc.arg(kingdom_id) AND killed_at IS NOT NULL;

-- One lord's blows in this cycle, added to.
-- name: RecordBossHit :one
INSERT INTO app.boss_hits (cycle_id, player_id, hits, damage, first_at, last_at)
VALUES (sqlc.arg(cycle_id), sqlc.arg(player_id), 1, sqlc.arg(damage), sqlc.arg(now), sqlc.arg(now))
ON CONFLICT (cycle_id, player_id) DO UPDATE
SET hits = app.boss_hits.hits + 1,
    damage = app.boss_hits.damage + excluded.damage,
    last_at = excluded.last_at
RETURNING *;

-- What one lord has done to this beast, for the blows they have left.
-- name: GetBossHit :one
SELECT * FROM app.boss_hits
WHERE cycle_id = sqlc.arg(cycle_id) AND player_id = sqlc.arg(player_id);

-- The damage list: who has hurt it most, with the names the screen draws.
-- name: ListBossDamage :many
SELECT h.*, p.username, p.display_name, p.level, p.avatar, p.cos_frame, p.cos_title,
       p.cos_color, p.cos_crest, p.vip_points
FROM app.boss_hits h
JOIN app.players p ON p.id = h.player_id
WHERE h.cycle_id = sqlc.arg(cycle_id)
ORDER BY h.damage DESC, h.first_at
LIMIT sqlc.arg(lim);

-- Every cycle whose window has shut and which nobody has paid out yet.
-- name: ListDueBossCycles :many
SELECT * FROM app.kingdom_bosses
WHERE settled_at IS NULL AND (ends_at <= sqlc.arg(now) OR killed_at IS NOT NULL)
ORDER BY ends_at
LIMIT sqlc.arg(lim);

-- Everyone who struck, for the paying out. Unpaid only: a settle that fell over
-- halfway through pays the rest and nobody twice.
-- name: ListUnpaidBossHits :many
SELECT * FROM app.boss_hits
WHERE cycle_id = sqlc.arg(cycle_id) AND paid_at IS NULL
ORDER BY damage DESC, first_at;

-- name: MarkBossHitPaid :exec
UPDATE app.boss_hits SET paid_at = sqlc.arg(now)
WHERE cycle_id = sqlc.arg(cycle_id) AND player_id = sqlc.arg(player_id);

-- name: SettleBossCycle :exec
UPDATE app.kingdom_bosses SET settled_at = sqlc.arg(now)
WHERE id = sqlc.arg(id) AND settled_at IS NULL;

-- ---------------------------------------------------------------------------
-- The wars
-- ---------------------------------------------------------------------------

-- This kingdom's war for the week, either side of the pair.
-- name: GetWarFor :one
SELECT * FROM app.wars
WHERE week = sqlc.arg(week) AND (a_id = sqlc.arg(kingdom_id) OR b_id = sqlc.arg(kingdom_id));

-- name: GetWar :one
SELECT * FROM app.wars WHERE id = sqlc.arg(id);

-- name: LockWar :one
SELECT * FROM app.wars WHERE id = sqlc.arg(id) FOR UPDATE;

-- A pair is drawn. Nothing comes back when the week already has this kingdom in
-- it, so the draw may run as often as it likes.
-- name: DrawWar :one
INSERT INTO app.wars (week, a_id, b_id, a_might, b_might, starts_at, ends_at)
VALUES (sqlc.arg(week), sqlc.arg(a_id), sqlc.narg(b_id), sqlc.arg(a_might), sqlc.arg(b_might),
        sqlc.arg(starts_at), sqlc.arg(ends_at))
ON CONFLICT DO NOTHING
RETURNING *;

-- Who each kingdom fought last week, so the draw does not repeat itself.
-- name: ListWarsInWeek :many
SELECT * FROM app.wars WHERE week = sqlc.arg(week);

-- The points, added where the attack was made.
-- name: AddWarPoints :one
UPDATE app.wars
SET a_points = a_points + sqlc.arg(a_points),
    b_points = b_points + sqlc.arg(b_points)
WHERE id = sqlc.arg(id)
RETURNING *;

-- One attack, written down: the day's three are counted from these rows.
-- name: RecordWarAttack :one
INSERT INTO app.war_attacks (war_id, attacker_id, defender_id, side, won, points,
                             held_points, routed, battle_id, created_at)
VALUES (sqlc.arg(war_id), sqlc.arg(attacker_id), sqlc.arg(defender_id), sqlc.arg(side),
        sqlc.arg(won), sqlc.arg(points), sqlc.arg(held_points), sqlc.arg(routed),
        sqlc.narg(battle_id), sqlc.arg(now))
RETURNING *;

-- How many attacks this lord has made since a moment: their day's three.
-- name: CountWarAttacksSince :one
SELECT count(*) FROM app.war_attacks
WHERE war_id = sqlc.arg(war_id) AND attacker_id = sqlc.arg(attacker_id)
  AND created_at >= sqlc.arg(since);

-- How many banners a defender has lost in this war.
-- name: CountBannersLost :one
SELECT count(*) FROM app.war_attacks
WHERE war_id = sqlc.arg(war_id) AND defender_id = sqlc.arg(defender_id) AND won;

-- The banners lost by every defender on one side, for the enemy list.
-- name: ListBannersLost :many
SELECT defender_id, count(*)::bigint AS lost
FROM app.war_attacks
WHERE war_id = sqlc.arg(war_id) AND won
GROUP BY defender_id;

-- The war log, newest first, with both names.
-- name: ListWarLog :many
SELECT w.*, a.display_name AS attacker_name, d.display_name AS defender_name
FROM app.war_attacks w
JOIN app.players a ON a.id = w.attacker_id
JOIN app.players d ON d.id = w.defender_id
WHERE w.war_id = sqlc.arg(war_id)
ORDER BY w.created_at DESC
LIMIT sqlc.arg(lim);

-- What each lord did for their side, biggest first: the Warlord is the top row.
-- name: ListWarScorers :many
SELECT w.attacker_id, w.side, sum(w.points)::bigint AS points, count(*)::bigint AS attacks,
       p.display_name, p.username
FROM app.war_attacks w
JOIN app.players p ON p.id = w.attacker_id
WHERE w.war_id = sqlc.arg(war_id)
GROUP BY w.attacker_id, w.side, p.display_name, p.username
ORDER BY sum(w.points) DESC
LIMIT sqlc.arg(lim);

-- Every war whose days are over and which nobody has paid out yet.
-- name: ListDueWars :many
SELECT * FROM app.wars
WHERE settled_at IS NULL AND ends_at <= sqlc.arg(now)
ORDER BY ends_at
LIMIT sqlc.arg(lim);

-- name: SettleWar :exec
UPDATE app.wars SET settled_at = sqlc.arg(now), winner_id = sqlc.narg(winner_id)
WHERE id = sqlc.arg(id) AND settled_at IS NULL;

-- The kingdoms that may be drawn: their id, their members and what their best
-- lords are worth together. The Might is the top N by the cached figure the
-- Army tab keeps, which is the same number the raid band and the leaderboards
-- read.
-- name: ListKingdomMusters :many
SELECT k.id, k.name, k.tag,
       (SELECT count(*) FROM app.players p
        WHERE p.kingdom_id = k.id AND p.state = 'active' AND NOT p.is_bot)::bigint AS members,
       (SELECT coalesce(sum(t.might), 0) FROM (
            SELECT p.might FROM app.players p
            WHERE p.kingdom_id = k.id AND p.state = 'active' AND NOT p.is_bot
            ORDER BY p.might DESC
            LIMIT sqlc.arg(top)
        ) t)::bigint AS might
FROM app.kingdoms k;

-- The lords of one kingdom as a war lists them: the strongest first, with what
-- the screen needs to draw a row.
-- name: ListWarMembers :many
SELECT id, username, display_name, level, avatar, might, cos_frame, cos_title,
       cos_color, cos_crest, vip_points
FROM app.players
WHERE kingdom_id = sqlc.arg(kingdom_id) AND state = 'active' AND NOT is_bot
ORDER BY might DESC
LIMIT sqlc.arg(lim);

-- ---------------------------------------------------------------------------
-- What the two jobs ask for
-- ---------------------------------------------------------------------------

-- The kingdoms a beast may rise against: nobody has one standing, and the last
-- one's window has shut. The WHERE is the cycle -- a kingdom that put its beast
-- down in an hour waits for the window all the same, or the forty-eight hours
-- would be forty-eight hours only for the kingdoms that could not kill it.
--
-- The wall is cut from the WHOLE muster (there is no LIMIT here, unlike the
-- war's draw): every member's blows are counted in it, so every member's Might
-- belongs in it. `cycles` is how many beasts this kingdom has seen, which is
-- which of the six comes round; `kills` is how many it has put down, which is
-- the next one's level.
-- name: ListKingdomsDueBoss :many
SELECT k.id, k.name,
       (SELECT count(*) FROM app.players p
        WHERE p.kingdom_id = k.id AND p.state = 'active' AND NOT p.is_bot)::bigint AS members,
       (SELECT coalesce(sum(p.might), 0) FROM app.players p
        WHERE p.kingdom_id = k.id AND p.state = 'active' AND NOT p.is_bot)::bigint AS might,
       (SELECT count(*) FROM app.kingdom_bosses b
        WHERE b.kingdom_id = k.id)::bigint AS cycles,
       (SELECT count(*) FROM app.kingdom_bosses b
        WHERE b.kingdom_id = k.id AND b.killed_at IS NOT NULL)::bigint AS kills
FROM app.kingdoms k
WHERE NOT EXISTS (
    SELECT 1 FROM app.kingdom_bosses b
    WHERE b.kingdom_id = k.id
      AND (b.settled_at IS NULL OR b.ends_at > sqlc.arg(now)))
ORDER BY k.id
LIMIT sqlc.arg(lim);

-- The last cycle a kingdom saw, standing or not: what the screen shows between
-- beasts, so a lord who looks the morning after is told what fell and when the
-- next one rises rather than shown an empty room.
-- name: LastKingdomBoss :one
SELECT * FROM app.kingdom_bosses
WHERE kingdom_id = sqlc.arg(kingdom_id)
ORDER BY started_at DESC
LIMIT 1;

-- The lords of a kingdom in one war, with what each of them did in it: the
-- points they took for the side and how many banners they have lost. One query,
-- because a war's roster is drawn a row at a time and a query per lord would be
-- a query per row.
-- name: ListWarRoster :many
SELECT p.id, p.username, p.display_name, p.level, p.avatar, p.might,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points,
       (SELECT coalesce(sum(w.points), 0) FROM app.war_attacks w
        WHERE w.war_id = sqlc.arg(war_id) AND w.attacker_id = p.id)::bigint AS points,
       (SELECT count(*) FROM app.war_attacks w
        WHERE w.war_id = sqlc.arg(war_id) AND w.defender_id = p.id AND w.won)::bigint AS banners_lost,
       (SELECT count(*) FROM app.war_attacks w
        WHERE w.war_id = sqlc.arg(war_id) AND w.attacker_id = sqlc.arg(me)
          AND w.defender_id = p.id)::bigint AS met
FROM app.players p
WHERE p.kingdom_id = sqlc.arg(kingdom_id) AND p.state = 'active' AND NOT p.is_bot
ORDER BY p.might DESC
LIMIT sqlc.arg(lim);

-- How many lords have struck this beast, and what they have done to it between
-- them. The damage list is drawn with a LIMIT and the valour share is a share of
-- what the WHOLE kingdom managed, so it is counted here rather than added up
-- from the rows the screen happens to show.
-- name: CountBossFighters :one
SELECT count(*)::bigint AS fighters, coalesce(sum(damage), 0)::bigint AS damage
FROM app.boss_hits WHERE cycle_id = sqlc.arg(cycle_id);

-- ---------------------------------------------------------------------------
-- What the desk reads (admin)
-- ---------------------------------------------------------------------------

-- Every beast standing right now, with the kingdom it stands against.
-- name: DeskBossStanding :many
SELECT b.id, b.kingdom_id, b.boss_id, b.level, b.hp_max, b.hp_left, b.members,
       b.kingdom_might, b.started_at, b.ends_at, b.killed_at,
       k.name AS kingdom_name, k.tag AS kingdom_tag,
       (SELECT count(*) FROM app.boss_hits h WHERE h.cycle_id = b.id)::bigint AS fighters
FROM app.kingdom_bosses b
JOIN app.kingdoms k ON k.id = b.kingdom_id
WHERE b.settled_at IS NULL
ORDER BY b.ends_at
LIMIT sqlc.arg(lim);

-- The calibration in the wild: how many cycles closed in the window, and how
-- many of them the kingdom actually put down. boss.json's share is set so this
-- sits between 65 and 80 per cent.
-- name: DeskBossSettled :one
SELECT count(*)::bigint AS cycles,
       count(*) FILTER (WHERE killed_at IS NOT NULL)::bigint AS killed,
       coalesce(sum(hp_max - hp_left), 0)::bigint AS damage,
       coalesce(avg(members), 0)::bigint AS members
FROM app.kingdom_bosses
WHERE settled_at >= sqlc.arg(since);

-- What the realm swung in the window.
-- name: DeskBossBlows :one
SELECT coalesce(sum(hits), 0)::bigint AS blows,
       count(*)::bigint AS lords,
       count(*) FILTER (WHERE paid_at IS NOT NULL)::bigint AS paid
FROM app.boss_hits
WHERE last_at >= sqlc.arg(since);

-- The week's wars, the busiest first.
-- name: DeskWars :many
SELECT w.id, w.week, w.a_id, w.b_id, w.a_points, w.b_points, w.a_might, w.b_might,
       w.starts_at, w.ends_at, w.settled_at, w.winner_id,
       a.name AS a_name, b.name AS b_name,
       (SELECT count(*) FROM app.war_attacks x WHERE x.war_id = w.id)::bigint AS attacks
FROM app.wars w
JOIN app.kingdoms a ON a.id = w.a_id
LEFT JOIN app.kingdoms b ON b.id = w.b_id
WHERE w.week = sqlc.arg(week)
ORDER BY (w.a_points + w.b_points) DESC
LIMIT sqlc.arg(lim);

-- And what the realm has done in them.
-- name: DeskWarAttacks :one
SELECT count(*)::bigint AS attacks,
       count(*) FILTER (WHERE won)::bigint AS wins,
       count(*) FILTER (WHERE routed)::bigint AS routs,
       count(DISTINCT attacker_id)::bigint AS lords,
       coalesce(sum(points + held_points), 0)::bigint AS points
FROM app.war_attacks
WHERE created_at >= sqlc.arg(since);
