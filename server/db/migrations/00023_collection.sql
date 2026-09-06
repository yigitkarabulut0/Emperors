-- +goose Up
-- +goose StatementBegin

-- The Collection: a second reason for an item to exist.
--
-- A locked owner decision in docs/PLAN.md ("Item sink: Sell + Collection", and
-- listed again as an M5 deliverable) that silently never shipped. Selling is the
-- only thing to do with gear you are not wearing, so a bag of 150 is 150 things
-- worth exactly their sell price and nothing else.
--
-- One row per DEFINITION, not per item: donating a second Rusted Arming Sword
-- adds nothing, which is what makes the sixty-third donation the interesting one.
CREATE TABLE app.player_collection (
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    def_id      text        NOT NULL,
    donated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, def_id)
);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.player_collection;
