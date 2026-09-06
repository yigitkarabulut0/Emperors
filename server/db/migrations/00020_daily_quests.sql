-- +goose Up
-- +goose StatementBegin

-- Daily quests: three a day, and a reason to come back tomorrow.
--
-- Only PROGRESS is stored. Which three quests a player has on a given day is a
-- pure function of (secret, player_id, local_day) — the same trick the shop uses
-- for its five-minute window, and for the same reasons: nothing to write when
-- the day turns over, no way for two devices to see different quests, and a
-- rebalance of the quest list cannot orphan rows.
--
-- Keyed by the player's LOCAL day, so "today" means today where they are. Rows
-- are small and one per player per day; old ones cost nothing and answer "did
-- they play on the 3rd".
CREATE TABLE app.player_quests (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    day        date        NOT NULL,

    -- The counters every quest kind reads from. Cheaper than a row per quest:
    -- three quests on one day almost always watch overlapping actions, and a
    -- counter that nothing is currently asking about costs one integer.
    collects   integer     NOT NULL DEFAULT 0,
    wins       integer     NOT NULL DEFAULT 0,
    buys       integer     NOT NULL DEFAULT 0,
    energy     integer     NOT NULL DEFAULT 0,

    -- Bit per quest slot. A mask rather than three booleans because the claim
    -- has to be idempotent in one UPDATE, and "set this bit if it is not set"
    -- is that statement.
    claimed    integer     NOT NULL DEFAULT 0,

    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, day)
);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.player_quests;
