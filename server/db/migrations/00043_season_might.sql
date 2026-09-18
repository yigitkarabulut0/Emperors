-- +goose Up
-- +goose StatementBegin

-- The season's Might-gained board (liveops.ranks season_might): a lord's
-- army Might when their season began -- their first deed in it -- so the
-- board can rank what they have gained since. Written once, with the row.
-- Rows the season already has are given the Might their lord holds now: they
-- are a day old, and a start measured from now is the honest one.
ALTER TABLE app.player_season ADD COLUMN might_start bigint;
UPDATE app.player_season ps SET might_start = p.might FROM app.players p WHERE p.id = ps.player_id;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.player_season DROP COLUMN IF EXISTS might_start;
-- +goose StatementEnd
