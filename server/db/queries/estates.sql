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

-- Credits whatever the estates have earned since the last settle.
--
-- Whole gold moves into the purse; the sub-gold remainder stays in the
-- accumulator so nothing is lost to rounding on a fast poll.
--
-- Two details that decide whether this is correct:
--
--   * elapsed is measured in MILLISECONDS. Truncating it to whole seconds meant
--     that a client polling four times a second earned exactly nothing, because
--     every individual call saw zero seconds elapsed and moved the anchor
--     anyway. Polling faster must never earn less.
--   * the anchor only moves when something was actually earned. Integer division
--     always rounds down, so a call that earns nothing must leave the clock
--     alone or the remainder is thrown away on every single request.
-- name: CreditTax :one
UPDATE app.players
SET gold = gold + (tax_milli_accrued + tax_milli_per_hour
        * GREATEST(0, (EXTRACT(EPOCH FROM (sqlc.arg(now)::timestamptz - tax_updated_at)) * 1000)::bigint)
        / 3600000) / 1000,
    tax_milli_accrued = (tax_milli_accrued + tax_milli_per_hour
        * GREATEST(0, (EXTRACT(EPOCH FROM (sqlc.arg(now)::timestamptz - tax_updated_at)) * 1000)::bigint)
        / 3600000) % 1000,
    tax_updated_at = sqlc.arg(now)::timestamptz
WHERE id = sqlc.arg(id)
  AND tax_milli_per_hour
        * GREATEST(0, (EXTRACT(EPOCH FROM (sqlc.arg(now)::timestamptz - tax_updated_at)) * 1000)::bigint)
        / 3600000 > 0
RETURNING *;

-- Rewrites the cached hourly rate. Must be called only after CreditTax, so the
-- time already earned is paid at the OLD rate.
-- name: SetTaxRate :exec
UPDATE app.players SET tax_milli_per_hour = $2 WHERE id = $1;
