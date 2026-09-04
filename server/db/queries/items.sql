-- name: ListPlayerItems :many
SELECT * FROM app.player_items WHERE player_id = $1 ORDER BY acquired_at DESC;

-- name: CountPlayerItems :one
SELECT count(*) FROM app.player_items WHERE player_id = $1;

-- name: GetPlayerItem :one
SELECT * FROM app.player_items WHERE id = $1 AND player_id = $2;

-- name: LockPlayerItem :one
SELECT * FROM app.player_items WHERE id = $1 AND player_id = $2 FOR UPDATE;

-- name: InsertPlayerItem :one
INSERT INTO app.player_items (
    player_id, def_id, slot, tier, ilvl, quality_pct, masterwork,
    attack, defense, speed, acquired_from, rolled_config_version
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
RETURNING *;

-- name: DeletePlayerItem :exec
DELETE FROM app.player_items WHERE id = $1 AND player_id = $2;

-- Clears whatever the player is wearing in this slot, so equipping is a
-- two-step swap that cannot transiently violate the one-item-per-slot index.
-- name: UnequipHeroSlot :exec
UPDATE app.player_items
SET equipped_on_hero = false
WHERE player_id = $1 AND slot = $2 AND equipped_on_hero;

-- name: SetHeroEquipped :exec
UPDATE app.player_items
SET equipped_on_hero = $3
WHERE id = $1 AND player_id = $2;

-- name: ListHeroEquipped :many
SELECT * FROM app.player_items WHERE player_id = $1 AND equipped_on_hero;
