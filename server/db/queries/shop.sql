-- name: GetShopState :one
SELECT * FROM app.shop_state WHERE player_id = $1;

-- name: LockShopState :one
SELECT * FROM app.shop_state WHERE player_id = $1 FOR UPDATE;

-- Creates the row on first use and resets it whenever the 5-minute window rolls
-- over, in one statement so two concurrent requests cannot both "reset" it.
-- name: UpsertShopWindow :one
INSERT INTO app.shop_state (player_id, window_id, purchased_mask, reroll_index)
VALUES ($1, $2, 0, 0)
ON CONFLICT (player_id) DO UPDATE
SET window_id      = EXCLUDED.window_id,
    purchased_mask = CASE WHEN app.shop_state.window_id = EXCLUDED.window_id
                          THEN app.shop_state.purchased_mask ELSE 0 END,
    reroll_index   = CASE WHEN app.shop_state.window_id = EXCLUDED.window_id
                          THEN app.shop_state.reroll_index ELSE 0 END
RETURNING *;

-- name: MarkShopSlotPurchased :one
UPDATE app.shop_state
SET purchased_mask = purchased_mask | $2
WHERE player_id = $1
RETURNING *;
