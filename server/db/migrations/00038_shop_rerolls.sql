-- +goose Up
-- +goose StatementBegin

-- The market's rerolls counted on the lord's own day, as the energy refills
-- are (00028): diamonds are sold, and a reroll is where diamonds reach rarity,
-- so there is a daily cap (items.shop.rerolls_per_day).
ALTER TABLE app.players
    ADD COLUMN shop_rerolls_day  date,
    ADD COLUMN shop_rerolls_used smallint NOT NULL DEFAULT 0 CHECK (shop_rerolls_used >= 0);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players DROP COLUMN IF EXISTS shop_rerolls_used;
ALTER TABLE app.players DROP COLUMN IF EXISTS shop_rerolls_day;
-- +goose StatementEnd
