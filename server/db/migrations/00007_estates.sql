-- +goose Up
-- +goose StatementBegin

-- Passive income accrues lazily, exactly like energy: (accrued, updated_at) and
-- a rate derived on read. Nothing sweeps every player, and nothing writes on
-- every request.
--
-- Uncollected tax is deliberately NOT stealable. That gives players a
-- discoverable, legitimate way to shelter income from raiders, and the offline
-- cap is what stops it becoming an infinite bank.
ALTER TABLE app.players
    ADD COLUMN tax_milli_accrued bigint      NOT NULL DEFAULT 0 CHECK (tax_milli_accrued >= 0),
    ADD COLUMN tax_updated_at    timestamptz NOT NULL DEFAULT now();

-- One row per (player, upgrade). Absent means level 0.
CREATE TABLE app.player_upgrades (
    player_id  uuid    NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    upgrade_id text    NOT NULL,
    level      integer NOT NULL DEFAULT 0 CHECK (level >= 0),
    PRIMARY KEY (player_id, upgrade_id)
) WITH (fillfactor = 85);

CREATE TABLE app.player_holdings (
    player_id  uuid    NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    holding_id text    NOT NULL,
    level      integer NOT NULL DEFAULT 0 CHECK (level >= 0),
    PRIMARY KEY (player_id, holding_id)
) WITH (fillfactor = 85);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.player_holdings;
DROP TABLE IF EXISTS app.player_upgrades;
ALTER TABLE app.players
    DROP COLUMN IF EXISTS tax_milli_accrued,
    DROP COLUMN IF EXISTS tax_updated_at;
