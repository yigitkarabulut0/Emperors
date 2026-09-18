-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- Deeds: what a player has done, counted per period
-- ============================================================================
-- Today's quests count four things in their own columns. Everything planned
-- after them counts more, over other stretches of time: weekly tasks count a
-- local week, the weekly boards a UTC week, a season its season, achievements a
-- lifetime. One table holds every counter, and one call (service.recordDeeds)
-- is where every action reports what it did.
--
-- scope is the stretch of time; period names which one:
--   life   0
--   week   the player's local Monday, as days since the epoch
--   uweek  the UTC Monday, as days since the epoch (boards everyone shares)
--   season a season's number;  event  an event's id   (added with those systems)
CREATE TABLE app.player_deeds (
    player_id uuid   NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    scope     text   NOT NULL CHECK (scope IN ('life', 'week', 'uweek', 'season', 'event')),
    period    bigint NOT NULL,
    deed      text   NOT NULL,
    value     bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, scope, period, deed)
)
-- Written on nearly every action; the free space keeps those updates HOT.
WITH (fillfactor = 80);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.player_deeds;
