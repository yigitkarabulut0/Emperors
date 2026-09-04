-- +goose Up
-- +goose StatementBegin

-- One-time onboarding grants. Booleans rather than a bitmask so a support
-- request ("did this player get their free recruit?") is answerable with a
-- glance at the row instead of arithmetic.
ALTER TABLE app.players
    ADD COLUMN free_slot_claimed    boolean NOT NULL DEFAULT false,
    ADD COLUMN free_recruit_claimed boolean NOT NULL DEFAULT false;

-- Existing accounts predate the grants; give them the same start.
UPDATE app.players SET free_slot_claimed = true, free_recruit_claimed = true
WHERE soldier_slots > 0;

-- +goose StatementEnd

-- +goose Down
ALTER TABLE app.players
    DROP COLUMN IF EXISTS free_slot_claimed,
    DROP COLUMN IF EXISTS free_recruit_claimed;
