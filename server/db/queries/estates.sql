-- name: ListUpgrades :many
SELECT * FROM app.player_upgrades WHERE player_id = $1;

-- name: ListHoldings :many
SELECT * FROM app.player_holdings WHERE player_id = $1;

-- Buys one level. The current level is in the WHERE clause, so two concurrent
-- taps cannot both see the same level and both succeed.
-- name: BuyUpgradeLevel :one
INSERT INTO app.player_upgrades (player_id, upgrade_id, level)
VALUES ($1, $2, 1)
ON CONFLICT (player_id, upgrade_id) DO UPDATE
SET level = app.player_upgrades.level + 1
WHERE app.player_upgrades.level = $3
RETURNING *;

-- name: BuyHoldingLevel :one
INSERT INTO app.player_holdings (player_id, holding_id, level)
VALUES ($1, $2, 1)
ON CONFLICT (player_id, holding_id) DO UPDATE
SET level = app.player_holdings.level + 1
WHERE app.player_holdings.level = $3
RETURNING *;

-- name: SettleTax :exec
UPDATE app.players
SET tax_milli_accrued = $2, tax_updated_at = $3
WHERE id = $1;

-- name: ClaimTax :one
UPDATE app.players
SET gold = gold + $2,
    tax_milli_accrued = 0,
    tax_updated_at = $3,
    action_seq = $4,
    last_seen_at = now()
WHERE id = $1
RETURNING *;
