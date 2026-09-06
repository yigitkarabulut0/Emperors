-- name: GetShopState :one
SELECT * FROM app.shop_state WHERE player_id = $1;

-- name: LockShopState :one
SELECT * FROM app.shop_state WHERE player_id = $1 FOR UPDATE;

-- Creates the row on first use and resets it whenever the 5-minute window rolls
-- over, in one statement so two concurrent requests cannot both "reset" it.
-- The luck column is written ONLY when the window turns. Holding it still for
-- the life of a window is what makes a shelf immutable: offers are recomputed on
-- every read and once more inside Buy, so a luck change taking effect mid-window
-- would swap the item under the player's finger.
-- name: UpsertShopWindow :one
INSERT INTO app.shop_state (player_id, window_id, purchased_mask, reroll_index, luck_bp)
VALUES ($1, $2, 0, 0, sqlc.arg(luck_bp))
ON CONFLICT (player_id) DO UPDATE
SET window_id      = EXCLUDED.window_id,
    purchased_mask = CASE WHEN app.shop_state.window_id = EXCLUDED.window_id
                          THEN app.shop_state.purchased_mask ELSE 0 END,
    reroll_index   = CASE WHEN app.shop_state.window_id = EXCLUDED.window_id
                          THEN app.shop_state.reroll_index ELSE 0 END,
    luck_bp        = CASE WHEN app.shop_state.window_id = EXCLUDED.window_id
                          THEN app.shop_state.luck_bp ELSE EXCLUDED.luck_bp END
RETURNING *;

-- name: MarkShopSlotPurchased :one
UPDATE app.shop_state
SET purchased_mask = purchased_mask | $2
WHERE player_id = $1
RETURNING *;

-- Pays for a reroll and advances the counter in one statement. The WHERE is the
-- guard: no row comes back if the player cannot afford it, and the window check
-- stops a reroll bought in one window from applying to the next.
-- name: PayForReroll :one
UPDATE app.players
SET diamonds = diamonds - $2, action_seq = $3, last_seen_at = now()
WHERE id = $1 AND diamonds >= $2
RETURNING *;

-- name: BumpReroll :one
UPDATE app.shop_state
SET reroll_index = reroll_index + 1
WHERE player_id = $1 AND window_id = $2
RETURNING *;
