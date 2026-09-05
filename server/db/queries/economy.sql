-- name: SpendGold :one
UPDATE app.players
SET gold = gold - $2, action_seq = $3, last_seen_at = now()
WHERE id = $1 AND gold >= $2
RETURNING *;

-- name: CreditGold :one
UPDATE app.players
SET gold = gold + $2, action_seq = $3, last_seen_at = now()
WHERE id = $1
RETURNING *;

-- name: RecordGold :exec
INSERT INTO app.gold_ledger (player_id, delta, balance_after, reason, ref_id)
VALUES ($1, $2, $3, $4, $5);

-- Moves gold between the purse and the vault in one statement, so the pair can
-- never be seen half-applied. The guards are in the WHERE: no row comes back if
-- the player cannot cover it, and the CHECK constraints refuse a negative side.
-- name: MoveToTreasury :one
UPDATE app.players
SET gold = gold - $2, treasury_gold = treasury_gold + $3,
    action_seq = $4, last_seen_at = now()
WHERE id = $1 AND gold >= $2
RETURNING *;

-- name: MoveFromTreasury :one
UPDATE app.players
SET gold = gold + $2, treasury_gold = treasury_gold - $2,
    action_seq = $3, last_seen_at = now()
WHERE id = $1 AND treasury_gold >= $2
RETURNING *;
