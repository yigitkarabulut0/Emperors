-- name: CreatePlayer :one
INSERT INTO app.players (username, display_name, energy_milli, reset_offset_minutes)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetPlayerByID :one
SELECT * FROM app.players WHERE id = $1;

-- name: GetPlayerByUsername :one
SELECT * FROM app.players WHERE lower(username) = lower($1);

-- Locks the row for the duration of the transaction. Every mutating action
-- takes this first, so two concurrent collects cannot both read the same energy
-- and both spend it.
-- name: LockPlayer :one
SELECT * FROM app.players WHERE id = $1 FOR UPDATE;

-- name: TouchPlayerSeen :exec
UPDATE app.players SET last_seen_at = now() WHERE id = $1;

-- Writes back a whole batch of players the presence registry has heard from.
--
-- This is what finally makes the comment in admin.sql true. last_seen_at was
-- only ever written as a side effect of the ~18 queries that MUTATE something,
-- so a player who opened the game, read their estates and put the phone down
-- was never recorded as active at all, and every "actives" number undercounted
-- everyone who was merely looking. The registry now records every authenticated
-- request in memory and flushes the set here once every thirty seconds -- one
-- statement regardless of how many players are online, instead of one write per
-- request.
--
-- The same statement records the day in app.player_days, so "who played on the
-- 3rd" is kept after last_seen_at has moved on: the active series and retention
-- read that, and a flush that cannot write one cannot write the other.
-- name: TouchPlayersSeen :exec
WITH seen AS (
    UPDATE app.players SET last_seen_at = now() WHERE id = ANY($1::uuid[]) RETURNING id
)
INSERT INTO app.player_days (player_id, day)
SELECT id, (now() AT TIME ZONE 'UTC')::date FROM seen
ON CONFLICT DO NOTHING;

-- The players seen recently, to repopulate the presence registry after a
-- restart. Without it a deploy shows every player leaving at once.
-- name: RecentlySeenPlayers :many
SELECT id, last_seen_at FROM app.players
WHERE last_seen_at > $1 AND NOT is_bot;

-- Spends level-up points. The WHERE clause carries the affordability check, so
-- the balance cannot go negative even under a concurrent double-tap.
-- name: SpendStatPoints :one
UPDATE app.players
SET stat_energy  = stat_energy  + $2,
    stat_attack  = stat_attack  + $3,
    stat_defense = stat_defense + $4,
    stat_points_unspent = stat_points_unspent - $5,
    action_seq   = $6
WHERE id = $1 AND stat_points_unspent >= $5
RETURNING *;

-- name: SetAvatar :one
UPDATE app.players SET avatar = $2, action_seq = $3
WHERE id = $1 RETURNING *;

-- Buys a new name. The WHERE carries the price, so a double tap cannot pay
-- twice, and players_username_lower_key refuses a name somebody else holds.
-- name: RenamePlayer :one
UPDATE app.players
SET username     = sqlc.arg(username),
    display_name = sqlc.arg(display_name),
    diamonds     = diamonds - sqlc.arg(diamonds),
    action_seq   = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id) AND diamonds >= sqlc.arg(diamonds)
RETURNING *;

-- Finds someone to invite. Prefix match rather than substring, so a search is
-- index-friendly and a player cannot enumerate the roster by typing one letter.
--
-- Bots are excluded: they exist to fill the Attack tab and cannot accept.
-- name: FindInvitablePlayers :many
SELECT id, username, display_name, avatar, level, kingdom_id
FROM app.players
WHERE state = 'active'
  AND is_bot = false
  AND id <> $1
  AND lower(username) LIKE lower($2)
ORDER BY level DESC
LIMIT 20;

-- name: BumpActionSeq :one
UPDATE app.players SET action_seq = $2 WHERE id = $1 RETURNING *;

-- Bumps today's quest counters, creating the row on first action of the day.
--
-- One statement so the hot paths (collect, attack, buy) pay a single round trip
-- and never a read-then-write race.
-- name: BumpQuestProgress :one
INSERT INTO app.player_quests (player_id, day, collects, wins, buys, energy,
                               stages, hunts, aids, blows, quest_ids)
VALUES (sqlc.arg(player_id), sqlc.arg(day), sqlc.arg(collects), sqlc.arg(wins),
        sqlc.arg(buys), sqlc.arg(energy), sqlc.arg(stages), sqlc.arg(hunts),
        sqlc.arg(aids), sqlc.arg(blows), sqlc.arg(quest_ids))
ON CONFLICT (player_id, day) DO UPDATE
SET collects = app.player_quests.collects + EXCLUDED.collects,
    wins     = app.player_quests.wins     + EXCLUDED.wins,
    buys     = app.player_quests.buys     + EXCLUDED.buys,
    energy   = app.player_quests.energy   + EXCLUDED.energy,
    stages   = app.player_quests.stages   + EXCLUDED.stages,
    hunts    = app.player_quests.hunts    + EXCLUDED.hunts,
    aids     = app.player_quests.aids     + EXCLUDED.aids,
    blows    = app.player_quests.blows    + EXCLUDED.blows,
    updated_at = now()
RETURNING *;

-- Creates the day's row with its three quests if it is not there yet, and
-- returns whatever the row holds either way.
--
-- The DO UPDATE is a no-op touch purely so RETURNING gives a row on conflict:
-- the quest_ids of an existing day are never rewritten, which is the whole
-- point — the board is frozen once it exists.
-- name: EnsureQuestDay :one
INSERT INTO app.player_quests (player_id, day, quest_ids)
VALUES (sqlc.arg(player_id), sqlc.arg(day), sqlc.arg(quest_ids))
ON CONFLICT (player_id, day) DO UPDATE
SET updated_at = app.player_quests.updated_at
RETURNING *;

-- name: GetQuestProgress :one
SELECT * FROM app.player_quests WHERE player_id = $1 AND day = $2;

-- Claims one quest slot. The bit test is inside the WHERE, so a double tap gets
-- zero rows and is paid once.
-- name: ClaimQuest :one
UPDATE app.player_quests
SET claimed = claimed | sqlc.arg(bit)
WHERE player_id = sqlc.arg(player_id) AND day = sqlc.arg(day)
  AND (claimed & sqlc.arg(bit)) = 0
RETURNING *;

-- Begins a new Legacy run.
--
-- Level, experience and every stat point go back to nothing; gold, gear,
-- soldiers and estates are untouched. The WHERE is the whole guard: it only
-- lands at the cap and below the stack limit, so a double tap cannot burn two
-- runs and a client cannot ask for one it has not earned.
-- name: BeginLegacy :one
UPDATE app.players
SET level               = 1,
    xp                  = 0,
    stat_energy         = 0,
    stat_attack         = 0,
    stat_defense        = 0,
    stat_points_unspent = 0,
    legacy              = legacy + 1,
    action_seq          = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
  AND level = sqlc.arg(level_cap)
  AND legacy < sqlc.arg(max_stacks)
RETURNING *;

-- Registers a device, or re-points one that moved to another account.
-- name: RegisterDevice :exec
INSERT INTO app.device_tokens (token, player_id, platform, seen_at)
VALUES (sqlc.arg(token), sqlc.arg(player_id), sqlc.arg(platform), now())
ON CONFLICT (token) DO UPDATE
SET player_id = EXCLUDED.player_id, platform = EXCLUDED.platform,
    seen_at = now(), revoked_at = NULL;

-- name: ListDevices :many
SELECT token, platform FROM app.device_tokens
WHERE player_id = $1 AND revoked_at IS NULL;

-- The password a player signed up with, to confirm a deletion with.
-- name: GetPasswordIdentity :one
SELECT * FROM app.identities WHERE player_id = $1 AND kind = 'password';

-- Removes a player and, through every foreign key's ON DELETE CASCADE, all that
-- was theirs: identities and sessions, items, soldiers, estates, battles, the
-- gold ledger, revenge, quests, deeds, mail, the collection, device tokens.
-- What has no foreign key outlives them on purpose: the diamond ledger and
-- app.player_days (see 00027 and 00033).
-- name: DeletePlayer :execrows
DELETE FROM app.players WHERE id = $1;
