-- +goose Up
-- +goose StatementBegin

-- Dalga 7 (PvE ve derinlik): the Conquest Campaign, the expeditions, and the
-- talent tree. The forge needs no table of its own -- it consumes rows in
-- app.player_items and writes one back with acquired_from 'forge', which
-- 00030 already allowed for.
--
-- LOCKING ORDER, everywhere in this feature: app.players first (a stage costs
-- energy, an expedition pays wages, a respec costs gold -- all of them touch
-- the lord's own row), then app.soldiers, then the table below. Nothing here
-- ever locks two lords: the campaign is a lord alone on a road.

-- ============================================================================
-- The campaign
-- ============================================================================
-- One row per stage a lord has FOUGHT AND WON. A stage never walked has no row,
-- which is what makes "the road opens one mile at a time" a question about
-- rows existing rather than a flag to keep in step.
--
-- stars is the best a lord has ever done on it, never the last: a lord who
-- three-starred a stage and later walked it again with a chipped sword has not
-- lost the chapter's chest. cleared_at is the FIRST clear, because the first
-- clear is what pays three times and hands over the boss's gear.
CREATE TABLE app.player_campaign (
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    chapter_id  text        NOT NULL,
    stage       integer     NOT NULL CHECK (stage >= 1),
    stars       integer     NOT NULL CHECK (stars BETWEEN 1 AND 3),
    cleared_at  timestamptz NOT NULL DEFAULT now(),
    last_at     timestamptz NOT NULL DEFAULT now(),
    -- How many times it has been walked, first clear included. The screen says
    -- it, and a deed counts it.
    clears      integer     NOT NULL DEFAULT 1 CHECK (clears >= 1),
    PRIMARY KEY (player_id, chapter_id, stage)
);

CREATE INDEX player_campaign_player_idx ON app.player_campaign (player_id);

-- The chapter chests: 12, 24 and 36 stars. One row per chest taken, by its
-- index in the chapter's own list, so a chest cannot be taken twice and a
-- balance that adds a fourth chest does not renumber the three already claimed.
CREATE TABLE app.player_campaign_chests (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    chapter_id text        NOT NULL,
    chest_ix   integer     NOT NULL CHECK (chest_ix >= 0),
    claimed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, chapter_id, chest_ix)
);

-- ============================================================================
-- The expeditions
-- ============================================================================
-- A soldier sent out for an hour, two, four or eight. The row IS the soldier's
-- absence: while one exists unreturned, that soldier does not fight, cannot be
-- rerolled, dismissed or re-geared, and the army's Might is the Might of who is
-- left in the yard.
--
-- The haul is rolled AT DISPATCH and written here, frozen. Rolling it on the
-- way home would make the reward a thing to wait on a clock for, and a lord who
-- was shown a range before the tap is owed a number the tap decided.
CREATE TABLE app.expeditions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    soldier_id uuid        NOT NULL REFERENCES app.soldiers(id) ON DELETE CASCADE,
    field_id   text        NOT NULL,
    sent_at    timestamptz NOT NULL DEFAULT now(),
    ends_at    timestamptz NOT NULL,
    -- Set when the haul has been handed over (or thrown away by a recall), so a
    -- return can never pay twice.
    settled_at timestamptz,
    -- 'home' when the soldier walked back with the haul, 'recalled' when they
    -- were called back early and brought nothing. Null while they are away.
    outcome    text        CHECK (outcome IN ('home', 'recalled')),

    gold_wages bigint      NOT NULL DEFAULT 0 CHECK (gold_wages >= 0),
    xp_wages   bigint      NOT NULL DEFAULT 0 CHECK (xp_wages >= 0),
    item_tier  text,

    rolled_config_version integer NOT NULL DEFAULT 1
);

-- One expedition per soldier at a time: the row is the absence, so two would
-- mean a soldier in two places.
CREATE UNIQUE INDEX expeditions_one_per_soldier_idx ON app.expeditions (soldier_id)
    WHERE settled_at IS NULL;
-- What the Army tab asks: who of mine is away, and who is due back.
CREATE INDEX expeditions_away_idx ON app.expeditions (player_id, ends_at)
    WHERE settled_at IS NULL;
-- The lord's own rail asks who is due, so the badge can say a scout is home;
-- there is no clock running over everybody's expeditions, because the haul is
-- handed over by the TAP that lets the soldier back in (a full bag has to be
-- able to refuse it, and a job cannot ask a sleeping lord to make room).

-- ============================================================================
-- The talent tree
-- ============================================================================
-- One row per rank BOUGHT. What a lord was given is worked out from their level
-- and their Legacies (talents.PointsAt) and never stored: a balance that moves
-- the first level or the step must move every lord's points with it, and a
-- stored total would be the number that disagreed.
CREATE TABLE app.player_talents (
    player_id uuid    NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    talent_id text    NOT NULL,
    ranks     integer NOT NULL CHECK (ranks >= 1),
    PRIMARY KEY (player_id, talent_id)
);

-- How many times this lord has taken it all back. The price doubles with it, to
-- a ceiling, so changing your mind is a decision and not a habit.
ALTER TABLE app.players
    ADD COLUMN IF NOT EXISTS talent_respecs integer NOT NULL DEFAULT 0
        CHECK (talent_respecs >= 0);

-- ============================================================================
-- The day's quests learn three new counters
-- ============================================================================
-- The pool asks for things a lord does; the wave added three kinds of doing.
-- Columns rather than a table for the same reason the first four are columns:
-- three quests on one day almost always watch overlapping actions, and a
-- counter nothing is currently asking about costs one integer.
ALTER TABLE app.player_quests
    ADD COLUMN IF NOT EXISTS stages integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hunts  integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS aids   integer NOT NULL DEFAULT 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.player_quests
    DROP COLUMN IF EXISTS stages,
    DROP COLUMN IF EXISTS hunts,
    DROP COLUMN IF EXISTS aids;
ALTER TABLE app.players DROP COLUMN IF EXISTS talent_respecs;
DROP TABLE IF EXISTS app.player_talents;
DROP TABLE IF EXISTS app.expeditions;
DROP TABLE IF EXISTS app.player_campaign_chests;
DROP TABLE IF EXISTS app.player_campaign;
-- +goose StatementEnd
