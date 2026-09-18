-- Dalga 7 (migration 00047): the Conquest Campaign, the expeditions and the
-- talent tree.

-- ---------------------------------------------------------------------------
-- The campaign
-- ---------------------------------------------------------------------------

-- Every mile this lord has walked. The map reads it whole: 120 rows at the very
-- most, and the screen needs all of them to draw the road behind you.
-- name: ListCampaign :many
SELECT * FROM app.player_campaign
WHERE player_id = sqlc.arg(player_id)
ORDER BY chapter_id, stage;

-- One stage, for the fight that is about to happen.
-- name: GetCampaignStage :one
SELECT * FROM app.player_campaign
WHERE player_id = sqlc.arg(player_id)
  AND chapter_id = sqlc.arg(chapter_id)
  AND stage = sqlc.arg(stage);

-- A stage cleared. stars keeps the BEST a lord has ever done, never the last: a
-- lord who three-starred a mile and later walked it with a chipped sword has
-- not lost the chapter's chest.
-- name: ClearCampaignStage :one
INSERT INTO app.player_campaign (player_id, chapter_id, stage, stars, cleared_at, last_at)
VALUES (sqlc.arg(player_id), sqlc.arg(chapter_id), sqlc.arg(stage), sqlc.arg(stars),
        sqlc.arg(now), sqlc.arg(now))
ON CONFLICT (player_id, chapter_id, stage) DO UPDATE
SET stars   = greatest(app.player_campaign.stars, excluded.stars),
    last_at = excluded.last_at,
    clears  = app.player_campaign.clears + 1
RETURNING *;

-- Every star this lord holds, which is what the chapter chests are asked for.
-- name: CountCampaignStars :one
SELECT coalesce(sum(stars), 0)::bigint AS stars
FROM app.player_campaign
WHERE player_id = sqlc.arg(player_id) AND chapter_id = sqlc.arg(chapter_id);

-- The chests already taken in a chapter.
-- name: ListCampaignChests :many
SELECT chest_ix FROM app.player_campaign_chests
WHERE player_id = sqlc.arg(player_id) AND chapter_id = sqlc.arg(chapter_id)
ORDER BY chest_ix;

-- One chest taken. Nothing comes back when it was already taken, so the caller
-- learns it was a second tap rather than paying twice.
-- name: ClaimCampaignChest :one
INSERT INTO app.player_campaign_chests (player_id, chapter_id, chest_ix, claimed_at)
VALUES (sqlc.arg(player_id), sqlc.arg(chapter_id), sqlc.arg(chest_ix), sqlc.arg(now))
ON CONFLICT DO NOTHING
RETURNING *;

-- ---------------------------------------------------------------------------
-- The expeditions
-- ---------------------------------------------------------------------------

-- Who of mine is away. The row is the soldier's absence, so this is also what
-- the Army tab asks before it lets anybody fight, reroll, dismiss or re-gear.
-- name: ListExpeditions :many
SELECT * FROM app.expeditions
WHERE player_id = sqlc.arg(player_id) AND settled_at IS NULL
ORDER BY ends_at;

-- One of mine, locked, for the tap that settles it.
-- name: LockExpedition :one
SELECT * FROM app.expeditions
WHERE id = sqlc.arg(id) AND player_id = sqlc.arg(player_id) AND settled_at IS NULL
FOR UPDATE;

-- A soldier sent out. The haul is already rolled: it is written here and frozen.
-- name: SendExpedition :one
INSERT INTO app.expeditions (player_id, soldier_id, field_id, sent_at, ends_at,
                             gold_wages, xp_wages, item_tier, rolled_config_version)
VALUES (sqlc.arg(player_id), sqlc.arg(soldier_id), sqlc.arg(field_id), sqlc.arg(now),
        sqlc.arg(ends_at), sqlc.arg(gold_wages), sqlc.arg(xp_wages), sqlc.narg(item_tier),
        sqlc.arg(config_version))
RETURNING *;

-- Settled: the soldier is home with the haul, or was called back with nothing.
-- The WHERE keeps a double tap from paying twice.
-- name: SettleExpedition :one
UPDATE app.expeditions
SET settled_at = sqlc.arg(now), outcome = sqlc.arg(outcome)
WHERE id = sqlc.arg(id) AND settled_at IS NULL
RETURNING *;

-- How many of this lord's soldiers are out, for the slot count.
-- name: CountExpeditions :one
SELECT count(*) FROM app.expeditions
WHERE player_id = sqlc.arg(player_id) AND settled_at IS NULL;

-- ---------------------------------------------------------------------------
-- The talent tree
-- ---------------------------------------------------------------------------

-- What this lord has bought. Read on every action that loads effects, so it is
-- one small query and never a join.
-- name: ListTalents :many
SELECT talent_id, ranks FROM app.player_talents
WHERE player_id = sqlc.arg(player_id)
ORDER BY talent_id;

-- One more rank.
-- name: BuyTalentRank :one
INSERT INTO app.player_talents (player_id, talent_id, ranks)
VALUES (sqlc.arg(player_id), sqlc.arg(talent_id), 1)
ON CONFLICT (player_id, talent_id) DO UPDATE
SET ranks = app.player_talents.ranks + 1
RETURNING *;

-- Every rank taken back. The gold and the count of respecs are the player row's.
-- name: ClearTalents :exec
DELETE FROM app.player_talents WHERE player_id = sqlc.arg(player_id);

-- name: BumpTalentRespecs :one
UPDATE app.players SET talent_respecs = talent_respecs + 1
WHERE id = sqlc.arg(player_id)
RETURNING talent_respecs;

-- Is this soldier away? Asked before a reroll, a dismissal or a change of gear:
-- the row IS the absence, so this is the one question.
-- name: SoldierIsAway :one
SELECT EXISTS (
    SELECT 1 FROM app.expeditions
    WHERE soldier_id = sqlc.arg(soldier_id) AND settled_at IS NULL
) AS away;

-- Energy spent on a stage, with the lord's own sequence moved in the same
-- statement: a campaign fight is the lord's own action, so it advances the
-- number their queued collects are counting on.
-- name: SpendEnergySeq :one
UPDATE app.players
SET energy_milli = sqlc.arg(energy_milli),
    energy_updated_at = sqlc.arg(energy_updated_at),
    action_seq = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Every chest this lord has taken, anywhere on the road. The badges ask once,
-- rather than once a chapter: the rail's heartbeat is polled, and ten questions
-- where one will do is how a heartbeat becomes a load.
-- name: ListAllCampaignChests :many
SELECT chapter_id, chest_ix FROM app.player_campaign_chests
WHERE player_id = sqlc.arg(player_id);

-- ---------------------------------------------------------------------------
-- The desk (admin): what the wave's four features are doing across the realm
-- ---------------------------------------------------------------------------

-- How far the realm has walked: one row per chapter, the lords standing in it
-- and the stars they hold there.
-- name: CampaignByChapter :many
SELECT chapter_id,
       count(DISTINCT player_id)::bigint AS lords,
       count(*)::bigint                  AS stages,
       coalesce(sum(stars), 0)::bigint   AS stars,
       coalesce(sum(clears), 0)::bigint  AS walks
FROM app.player_campaign
GROUP BY chapter_id
ORDER BY chapter_id;

-- The miles walked since a moment, and how many of them were first clears.
-- name: CampaignSince :one
SELECT count(*) FILTER (WHERE cleared_at >= sqlc.arg(since))::bigint AS first_clears,
       coalesce(sum(clears) FILTER (WHERE last_at >= sqlc.arg(since)), 0)::bigint AS walks
FROM app.player_campaign;

-- The roads, as they stand: one row per field, who is out and who is at the
-- gate waiting to be let in.
-- name: ExpeditionsByField :many
SELECT field_id,
       count(*)::bigint AS away,
       count(*) FILTER (WHERE ends_at <= now())::bigint AS at_gate
FROM app.expeditions
WHERE settled_at IS NULL
GROUP BY field_id
ORDER BY field_id;

-- What the roads paid since a moment, and what was thrown away by a recall.
-- name: ExpeditionsSince :one
SELECT count(*) FILTER (WHERE outcome = 'home')::bigint      AS home,
       count(*) FILTER (WHERE outcome = 'recalled')::bigint  AS recalled,
       coalesce(sum(gold_wages) FILTER (WHERE outcome = 'home'), 0)::bigint AS gold_wages,
       coalesce(sum(xp_wages) FILTER (WHERE outcome = 'home'), 0)::bigint   AS xp_wages
FROM app.expeditions
WHERE settled_at >= sqlc.arg(since);

-- The anvil: what it has made since a moment, by the rank that came out.
-- name: ForgedSince :many
SELECT tier, count(*)::bigint AS made
FROM app.player_items
WHERE acquired_from = 'forge' AND acquired_at >= sqlc.arg(since)
GROUP BY tier
ORDER BY count(*) DESC;

-- And what it burnt for them: the fee is a gold ledger row of its own.
-- name: ForgeGoldSince :one
SELECT coalesce(-sum(delta), 0)::bigint AS gold
FROM app.gold_ledger
WHERE reason = 'forge' AND created_at >= sqlc.arg(since);

-- The tree: which ranks the realm is buying.
-- name: TalentsPicked :many
SELECT talent_id,
       count(*)::bigint                AS lords,
       coalesce(sum(ranks), 0)::bigint AS ranks
FROM app.player_talents
GROUP BY talent_id
ORDER BY sum(ranks) DESC
LIMIT sqlc.arg(lim);

-- And how often it changes its mind.
-- name: TalentRespecs :one
SELECT count(*) FILTER (WHERE talent_respecs > 0)::bigint AS lords,
       coalesce(sum(talent_respecs), 0)::bigint           AS respecs
FROM app.players;
