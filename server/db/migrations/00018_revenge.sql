-- +goose Up
-- +goose StatementBegin

-- A raid you lost earns you one strike back.
--
-- This is the piece that makes the battle log worth opening and, later, the push
-- notification worth allowing: "somebody took your gold" is a loss you can do
-- nothing about, and "somebody took your gold, and you have until tomorrow to
-- take it back" is a reason to open the game.
--
-- The token is spent, not merely expired, so the count of unused rows is also
-- the badge on the Fight tab. One token per battle: no battle can be avenged
-- twice, which is what the primary key enforces rather than a check in Go.
CREATE TABLE app.revenge_tokens (
    battle_id   uuid        PRIMARY KEY REFERENCES app.battles(id) ON DELETE CASCADE,
    -- The wronged party, and who wronged them.
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    target_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- The one query that runs on every Fight tab open: my live, unspent tokens.
-- Partial, because a spent token is never looked up again.
CREATE INDEX revenge_open_idx ON app.revenge_tokens (player_id, expires_at DESC)
    WHERE used_at IS NULL;

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.revenge_tokens;
