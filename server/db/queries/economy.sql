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
