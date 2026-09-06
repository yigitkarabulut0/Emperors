-- +goose Up
-- +goose StatementBegin

-- Might, cached on the player row.
--
-- It is derived from the whole roster and its gear, so ranking on it meant
-- assembling every player's army — which is why there has never been a player
-- leaderboard, only a kingdom one. Cached the same way tax_milli_per_hour is
-- (00011): written when the thing that produces it is next computed, which for
-- an army is every time the Army tab or a raid reads it.
--
-- Stale by design, and harmlessly so: a rank recomputed every few minutes from
-- a value refreshed on every army read is exactly as current as a leaderboard
-- needs to be.
ALTER TABLE app.players
    ADD COLUMN might bigint NOT NULL DEFAULT 0;

-- Ranked snapshots.
--
-- Rebuilt whole inside one transaction rather than queried live: a live ORDER BY
-- over every player on each request is the query that quietly becomes the
-- slowest thing in the game, and a rank that changes while you scroll reads as
-- broken. Truncate-and-fill in a transaction means readers always see one
-- consistent generation.
CREATE TABLE app.leaderboard_entries (
    board      text        NOT NULL,
    rank       integer     NOT NULL,
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    value      bigint      NOT NULL,
    PRIMARY KEY (board, rank)
);

-- "Where am I" without scanning the board.
CREATE INDEX leaderboard_player_idx ON app.leaderboard_entries (player_id);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.leaderboard_entries;
ALTER TABLE app.players DROP COLUMN IF EXISTS might;
