-- name: ListSoldiers :many
SELECT * FROM app.soldiers WHERE player_id = $1 ORDER BY slot_index;

-- name: GetSoldier :one
SELECT * FROM app.soldiers WHERE id = $1 AND player_id = $2;

-- name: LockSoldier :one
SELECT * FROM app.soldiers WHERE id = $1 AND player_id = $2 FOR UPDATE;

-- Recruiting into an occupied slot replaces the occupant, so this is an upsert
-- rather than an insert.
-- name: UpsertSoldier :one
INSERT INTO app.soldiers (player_id, slot_index, type_id, tier, level, name, rolled_config_version)
VALUES ($1,$2,$3,$4,$5,$6,$7)
ON CONFLICT (player_id, slot_index) DO UPDATE
SET type_id = EXCLUDED.type_id,
    tier    = EXCLUDED.tier,
    level   = EXCLUDED.level,
    name    = EXCLUDED.name,
    recruited_at = now(),
    rolled_config_version = EXCLUDED.rolled_config_version
RETURNING *;

-- name: SetSoldierLevel :one
UPDATE app.soldiers SET level = $3 WHERE id = $1 AND player_id = $2 RETURNING *;

-- name: BuySoldierSlot :one
UPDATE app.players
SET soldier_slots = soldier_slots + 1,
    gold = gold - $2,
    action_seq = $3
WHERE id = $1 AND gold >= $2 AND soldier_slots = $4
RETURNING *;

-- name: ListItemsForSoldiers :many
SELECT * FROM app.player_items
WHERE player_id = $1 AND equipped_soldier_id IS NOT NULL;

-- Frees the soldier's slot before the new item goes in, so the unique index
-- never sees two items in one slot even transiently.
-- name: UnequipSoldierSlot :exec
UPDATE app.player_items
SET equipped_soldier_id = NULL
WHERE player_id = $1 AND equipped_soldier_id = $2 AND slot = $3;

-- name: SetSoldierEquipped :exec
UPDATE app.player_items
SET equipped_soldier_id = $3, equipped_on_hero = false
WHERE id = $1 AND player_id = $2;

-- Dismissing a soldier must not destroy its gear; the items return to the bag.
-- name: ReleaseSoldierItems :exec
UPDATE app.player_items SET equipped_soldier_id = NULL
WHERE player_id = $1 AND equipped_soldier_id = $2;

-- name: ClaimFreeSlot :one
UPDATE app.players
SET soldier_slots = soldier_slots + 1,
    free_slot_claimed = true,
    action_seq = $2
WHERE id = $1 AND free_slot_claimed = false AND soldier_slots = 0
RETURNING *;

-- name: ClaimFreeRecruit :one
UPDATE app.players
SET free_recruit_claimed = true, action_seq = $2
WHERE id = $1 AND free_recruit_claimed = false
RETURNING *;

-- name: DeleteSoldier :exec
DELETE FROM app.soldiers WHERE id = $1 AND player_id = $2;
