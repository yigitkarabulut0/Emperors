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

-- The storehouse (migration 00040, game/estates.Fill).
--
-- Settles the storehouse at the rate and capacity it has been filling at, then
-- stores the new pair: a holding bought, a level reached or a Tithe Barn level
-- never pays for the hours before it at the new rate. The sum is Fill's, in SQL,
-- so a settle racing a collect is one row update, never two views of the row:
-- what is over the capacity stays and grows no more; below it, it grows to it.
-- Elapsed time is in milliseconds, so a settle on every request loses nothing.
-- name: RefreshStorehouse :exec
UPDATE app.players
SET storehouse_milli = LEAST(GREATEST(storehouse_milli, storehouse_cap_milli),
                             storehouse_milli + tax_milli_per_hour
                               * LEAST(34560000000::bigint,
                                       GREATEST(0, floor(EXTRACT(EPOCH FROM (sqlc.arg(now)::timestamptz - storehouse_at)) * 1000)::bigint))
                               / 3600000),
    storehouse_at        = GREATEST(storehouse_at, sqlc.arg(now)::timestamptz),
    tax_milli_per_hour   = sqlc.arg(rate),
    storehouse_cap_milli = sqlc.arg(cap_milli)
WHERE id = sqlc.arg(id);

-- Carries the storehouse's whole gold into the purse. The caller settled it on
-- the locked row; the sub-gold remainder stays behind.
-- name: CarryStorehouseToPurse :one
UPDATE app.players
SET gold             = gold + sqlc.arg(gold)::bigint,
    storehouse_milli = sqlc.arg(left_milli),
    storehouse_at    = sqlc.arg(now),
    action_seq       = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Carries it into the vault instead, less the deposit fee (burned), the purse
-- untouched: gold that goes straight to the vault never passes a raider.
-- name: CarryStorehouseToTreasury :one
UPDATE app.players
SET treasury_gold    = treasury_gold + sqlc.arg(banked)::bigint,
    storehouse_milli = sqlc.arg(left_milli),
    storehouse_at    = sqlc.arg(now),
    action_seq       = sqlc.arg(action_seq)
WHERE id = sqlc.arg(id)
RETURNING *;
