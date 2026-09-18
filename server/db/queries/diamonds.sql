-- The diamond ledger. See migration 00027 for why it has no foreign key.

-- name: RecordDiamonds :exec
INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, debt_after, reason, class, ref_id)
VALUES (sqlc.arg(player_id), sqlc.arg(delta), sqlc.arg(gross), sqlc.arg(balance_after),
        sqlc.arg(debt_after), sqlc.arg(reason), sqlc.arg(class), sqlc.narg(ref_id));

-- Credits diamonds, repaying any refund debt first.
--
-- Both right-hand sides read the row as it was, so the pair is exact in one
-- statement: a player owing 50 who is granted 30 keeps 0 and owes 20; granted
-- 80, they keep 30 and owe nothing. players_debt_means_empty holds either way.
-- name: CreditDiamonds :one
UPDATE app.players
SET diamonds     = diamonds + GREATEST(0, sqlc.arg(amount)::bigint - diamond_debt),
    diamond_debt = GREATEST(0, diamond_debt - sqlc.arg(amount)::bigint)
WHERE id = sqlc.arg(id)
RETURNING *;

-- A player's diamond history, newest first, for the admin panel.
-- name: ListDiamondLedger :many
SELECT id, delta, gross, balance_after, debt_after, reason, class, ref_id, created_at
FROM app.diamond_ledger
WHERE player_id = sqlc.arg(player_id)
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(lim) OFFSET sqlc.arg(off);

-- Diamonds created and destroyed by reason over a window: the premium half of
-- the economy dashboard. Opening balances are left out -- they are not a flow.
-- name: DiamondFlows :many
SELECT reason, class,
       sum(CASE WHEN gross > 0 THEN gross ELSE 0 END)::bigint AS created,
       sum(CASE WHEN gross < 0 THEN -gross ELSE 0 END)::bigint AS destroyed,
       count(*)::bigint AS entries
FROM app.diamond_ledger
WHERE created_at > now() - (sqlc.arg(days)::int * interval '1 day')
  AND class <> 'opening'
GROUP BY reason, class
ORDER BY greatest(sum(CASE WHEN gross > 0 THEN gross ELSE 0 END),
                  sum(CASE WHEN gross < 0 THEN -gross ELSE 0 END)) DESC;
