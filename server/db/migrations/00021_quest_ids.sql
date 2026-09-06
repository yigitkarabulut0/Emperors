-- +goose Up
-- +goose StatementBegin

-- The day's three quests, frozen the first time they are looked at.
--
-- They were a pure function of (secret, player, day) and that was almost right:
-- the selection ALSO filtered the pool by the player's level, so levelling up
-- mid-day changed which tasks were eligible and reshuffled the draw. Observed
-- live — a fresh account's board changed between two requests a second apart
-- because thirty-two collects took it past level 2.
--
-- That is worse than cosmetic. `claimed` is a bit per SLOT, so a shifting slot
-- order means a bit set for one quest can be read as another quest's.
--
-- Storing the ids makes the day's board immutable once it exists, which is what
-- a daily has to be.
ALTER TABLE app.player_quests
    ADD COLUMN quest_ids text[] NOT NULL DEFAULT '{}';

-- +goose StatementEnd

-- +goose Down
ALTER TABLE app.player_quests DROP COLUMN IF EXISTS quest_ids;
