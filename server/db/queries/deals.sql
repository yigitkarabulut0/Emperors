-- The Royal Store's daily deals. See migration 00035 and service/deals.go.

-- name: GetDeals :one
SELECT * FROM app.player_deals WHERE player_id = sqlc.arg(player_id);

-- Writes a day's deals. A row for the same day is left as it is -- whoever
-- looked first fixed it -- and the row as it now stands comes back.
-- name: PutDeals :one
INSERT INTO app.player_deals (player_id, day, slots, claimed)
VALUES (sqlc.arg(player_id), sqlc.arg(day), sqlc.arg(slots), 0)
ON CONFLICT (player_id) DO UPDATE
SET day = EXCLUDED.day, slots = EXCLUDED.slots, claimed = 0
WHERE app.player_deals.day <> EXCLUDED.day
RETURNING *;

-- Marks one slot claimed, once, on its own day. No row: stale or already taken.
-- name: ClaimDealSlot :one
UPDATE app.player_deals SET claimed = claimed | sqlc.arg(bit)::int
WHERE player_id = sqlc.arg(player_id) AND day = sqlc.arg(day)
  AND claimed & sqlc.arg(bit)::int = 0
RETURNING *;
