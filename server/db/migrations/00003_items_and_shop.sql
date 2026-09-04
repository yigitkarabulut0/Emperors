-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- Item instances
-- ============================================================================
-- Stats are FROZEN here at acquisition rather than derived live from the active
-- config. A rebalance must never nerf gear a player already paid for.
-- rolled_config_version records which rules produced them, for forensics.
--
-- The equipped-on pointer lives on the ITEM row, not as three item-id columns on
-- its holder. That makes "one item, two holders" structurally impossible instead
-- of something application code has to remember.
CREATE TABLE app.player_items (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id           uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,

    def_id              text        NOT NULL,
    slot                text        NOT NULL CHECK (slot IN ('weapon','armor','horse')),
    tier                text        NOT NULL,
    ilvl                integer     NOT NULL CHECK (ilvl >= 1),
    quality_pct         integer     NOT NULL CHECK (quality_pct BETWEEN 1 AND 1000),
    masterwork          boolean     NOT NULL DEFAULT false,

    attack              bigint      NOT NULL DEFAULT 0 CHECK (attack  >= 0),
    defense             bigint      NOT NULL DEFAULT 0 CHECK (defense >= 0),
    speed               bigint      NOT NULL DEFAULT 0 CHECK (speed   >= 0),

    equipped_on_hero    boolean     NOT NULL DEFAULT false,
    -- Soldiers arrive in M3. The column exists now so equipping onto a soldier
    -- is a write, not a migration.
    equipped_soldier_id uuid,

    acquired_at            timestamptz NOT NULL DEFAULT now(),
    acquired_from          text        NOT NULL DEFAULT 'shop'
                                       CHECK (acquired_from IN ('shop','milestone','loot','recruit','admin')),
    rolled_config_version  integer     NOT NULL DEFAULT 1,

    -- One item cannot be worn by the player and a soldier at the same time.
    CONSTRAINT player_items_one_holder
        CHECK (NOT (equipped_on_hero AND equipped_soldier_id IS NOT NULL))
) WITH (fillfactor = 90);

CREATE INDEX player_items_player_idx ON app.player_items (player_id);

-- The player may wear exactly one item per slot. A partial unique index makes
-- double-equipping impossible at the database level rather than by convention.
CREATE UNIQUE INDEX player_items_hero_slot_key
    ON app.player_items (player_id, slot)
    WHERE equipped_on_hero;

-- ============================================================================
-- Shop
-- ============================================================================
-- Offers are NOT stored. They are a pure function of
-- (secret, player_id, window_id, reroll_index), so there is nothing to refresh
-- on a schedule and a client cannot reroll by retrying a request. Only what the
-- player did persists: which slots were bought and how many rerolls were paid for.
CREATE TABLE app.shop_state (
    player_id       uuid    PRIMARY KEY REFERENCES app.players(id) ON DELETE CASCADE,
    window_id       bigint  NOT NULL,
    purchased_mask  integer NOT NULL DEFAULT 0 CHECK (purchased_mask >= 0),
    reroll_index    integer NOT NULL DEFAULT 0 CHECK (reroll_index >= 0)
);

-- ============================================================================
-- Gold ledger
-- ============================================================================
-- Every gold movement, so the economy can be audited and a suspicious balance
-- can be explained rather than guessed at.
--
-- Deliberately a plain table for now. It converts to monthly RANGE partitions
-- (with created_at in the primary key) before launch; doing that now, at zero
-- rows, would add partition maintenance for no benefit.
CREATE TABLE app.gold_ledger (
    id            bigserial   PRIMARY KEY,
    player_id     uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    delta         bigint      NOT NULL,
    balance_after bigint      NOT NULL,
    reason        text        NOT NULL,
    ref_id        text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX gold_ledger_player_idx ON app.gold_ledger (player_id, created_at DESC);
CREATE INDEX gold_ledger_reason_idx ON app.gold_ledger (reason, created_at DESC);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.gold_ledger;
DROP TABLE IF EXISTS app.shop_state;
DROP TABLE IF EXISTS app.player_items;
