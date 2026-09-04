-- +goose Up
-- +goose StatementBegin

ALTER TABLE app.players
    ADD COLUMN soldier_slots integer NOT NULL DEFAULT 0
        CHECK (soldier_slots >= 0 AND soldier_slots <= 32);

-- ============================================================================
-- Soldiers
-- ============================================================================
-- Stats are derived, never stored: (type, tier, level) plus the active config is
-- enough, and storing them would mean a Train action had to rewrite them while
-- a rebalance silently could not.
--
-- slot_index is 1-based and unique per player, so a soldier always occupies a
-- known position and the roster has a stable order.
CREATE TABLE app.soldiers (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    slot_index  integer     NOT NULL CHECK (slot_index BETWEEN 1 AND 32),

    type_id     text        NOT NULL,
    tier        text        NOT NULL,
    -- The level the soldier fights at. Set at recruitment, raised by Train, and
    -- never allowed past the player's own level.
    level       integer     NOT NULL CHECK (level >= 1),

    name        text        NOT NULL,
    recruited_at timestamptz NOT NULL DEFAULT now(),
    rolled_config_version integer NOT NULL DEFAULT 1
);

CREATE UNIQUE INDEX soldiers_player_slot_key ON app.soldiers (player_id, slot_index);
CREATE INDEX soldiers_player_idx ON app.soldiers (player_id);

-- A soldier's gear points at the soldier, mirroring how hero gear points at the
-- hero. One item still cannot have two holders (player_items_one_holder), and
-- this index adds the other half: one item per slot per soldier.
CREATE UNIQUE INDEX player_items_soldier_slot_key
    ON app.player_items (equipped_soldier_id, slot)
    WHERE equipped_soldier_id IS NOT NULL;

ALTER TABLE app.player_items
    ADD CONSTRAINT player_items_soldier_fk
    FOREIGN KEY (equipped_soldier_id) REFERENCES app.soldiers(id) ON DELETE SET NULL;

-- +goose StatementEnd

-- +goose Down
ALTER TABLE app.player_items DROP CONSTRAINT IF EXISTS player_items_soldier_fk;
DROP INDEX IF EXISTS app.player_items_soldier_slot_key;
DROP TABLE IF EXISTS app.soldiers;
ALTER TABLE app.players DROP COLUMN IF EXISTS soldier_slots;
