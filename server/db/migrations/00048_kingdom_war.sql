-- +goose Up
-- +goose StatementBegin

-- Dalga 8 (Krallik Boss ve Savaslari): the two things a kingdom does together.
--
-- LOCKING ORDER, everywhere in this feature: app.players (ascending uuid), then
-- app.kingdoms (ascending id), then the rows below. A war attack touches two
-- lords of two kingdoms, so it takes the players in uuid order exactly as a
-- raid does (LockTwoPlayers) and never holds a kingdom row while waiting for a
-- player's.

-- ============================================================================
-- The boss
-- ============================================================================
-- One beast per kingdom per cycle. The row IS the cycle: it carries which beast
-- came round, how much health it was given, what is left of it, and when the
-- window shuts. A kingdom with no row has no beast standing.
--
-- level is how many times THIS kingdom has put one down, which is what makes
-- the next one harder and its chests worth more.
CREATE TABLE app.kingdom_bosses (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kingdom_id  uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    boss_id     text        NOT NULL,
    level       integer     NOT NULL DEFAULT 1 CHECK (level >= 1),
    -- What it was given, and what is left. hp_max is kept so a bar can be drawn
    -- after the cycle has closed, and so the damage list can be read as shares.
    hp_max      bigint      NOT NULL CHECK (hp_max > 0),
    hp_left     bigint      NOT NULL CHECK (hp_left >= 0),
    -- The muster the wall was cut from: what the kingdom was worth when the
    -- beast rose. A kingdom that grows mid-cycle does not grow its own wall.
    kingdom_might bigint    NOT NULL DEFAULT 0,
    members     integer     NOT NULL DEFAULT 0,

    started_at  timestamptz NOT NULL DEFAULT now(),
    ends_at     timestamptz NOT NULL,
    -- When it fell, and who struck last. Null while it still stands.
    killed_at   timestamptz,
    killed_by   uuid        REFERENCES app.players(id) ON DELETE SET NULL,
    -- When the chests were paid out, so a cycle pays once however many times
    -- the job runs.
    settled_at  timestamptz,

    rolled_config_version integer NOT NULL DEFAULT 1
);

-- One beast standing per kingdom: the index is the rule.
CREATE UNIQUE INDEX kingdom_bosses_one_standing_idx ON app.kingdom_bosses (kingdom_id)
    WHERE settled_at IS NULL;
-- What the settling job asks: which cycles are over and not yet paid.
CREATE INDEX kingdom_bosses_due_idx ON app.kingdom_bosses (ends_at)
    WHERE settled_at IS NULL;
CREATE INDEX kingdom_bosses_kingdom_idx ON app.kingdom_bosses (kingdom_id, started_at DESC);

-- Every blow struck. One row per lord per cycle, not per swing: what the damage
-- list and the chests read is the TOTAL, and a row per swing would make the
-- list a sum over thousands of rows on the hot path.
CREATE TABLE app.boss_hits (
    cycle_id   uuid        NOT NULL REFERENCES app.kingdom_bosses(id) ON DELETE CASCADE,
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    hits       integer     NOT NULL DEFAULT 0 CHECK (hits >= 0),
    damage     bigint      NOT NULL DEFAULT 0 CHECK (damage >= 0),
    first_at   timestamptz NOT NULL DEFAULT now(),
    last_at    timestamptz NOT NULL DEFAULT now(),
    -- What the lord was paid when the cycle closed, so a second settle pays
    -- nobody twice.
    paid_at    timestamptz,
    PRIMARY KEY (cycle_id, player_id)
);

-- The damage list, biggest first: what the screen shows and what the first
-- three diamonds are decided by.
CREATE INDEX boss_hits_damage_idx ON app.boss_hits (cycle_id, damage DESC);

-- ============================================================================
-- The wars
-- ============================================================================
-- One row per war, keyed by the week it was drawn in. A bye is a row with no
-- second kingdom: the kingdom is told it sat the week out rather than left
-- wondering.
CREATE TABLE app.wars (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The Monday of the week the pairs were drawn in, so a week is one key and
    -- the draw is idempotent however many times the job runs.
    week       date        NOT NULL,
    a_id       uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    b_id       uuid        REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    a_points   integer     NOT NULL DEFAULT 0,
    b_points   integer     NOT NULL DEFAULT 0,
    -- What each side was worth when they were drawn: the pair was made on it,
    -- so it is kept with the pair.
    a_might    bigint      NOT NULL DEFAULT 0,
    b_might    bigint      NOT NULL DEFAULT 0,

    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    -- Set when the week has been paid out; the winner is written with it.
    settled_at timestamptz,
    winner_id  uuid        REFERENCES app.kingdoms(id) ON DELETE SET NULL
);

-- A kingdom is in one war a week, and the pair is drawn once.
CREATE UNIQUE INDEX wars_week_a_idx ON app.wars (week, a_id);
CREATE UNIQUE INDEX wars_week_b_idx ON app.wars (week, b_id) WHERE b_id IS NOT NULL;
CREATE INDEX wars_due_idx ON app.wars (ends_at) WHERE settled_at IS NULL;

-- Every attack made in a war. A lord's three a day are counted from these rows
-- rather than from a counter, so a restart never hands anybody a fresh three,
-- and the war log is the same rows read back.
CREATE TABLE app.war_attacks (
    id          bigserial   PRIMARY KEY,
    war_id      uuid        NOT NULL REFERENCES app.wars(id) ON DELETE CASCADE,
    attacker_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    defender_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    -- Which side the attacker fought for, so the points can be added up per
    -- side without joining back to the kingdoms (a lord may leave mid-war).
    side        text        NOT NULL CHECK (side IN ('a', 'b')),
    won         boolean     NOT NULL,
    points      integer     NOT NULL DEFAULT 0,
    -- What the defender's kingdom took for holding, so both halves of one
    -- attack are in one row.
    held_points integer     NOT NULL DEFAULT 0,
    -- Whether the defender had already lost every banner when this landed.
    routed      boolean     NOT NULL DEFAULT false,
    battle_id   uuid,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- What the day's three are counted from, and what the log reads.
CREATE INDEX war_attacks_attacker_idx ON app.war_attacks (war_id, attacker_id, created_at DESC);
CREATE INDEX war_attacks_defender_idx ON app.war_attacks (war_id, defender_id);
CREATE INDEX war_attacks_log_idx ON app.war_attacks (war_id, created_at DESC);

-- A blow at the kingdom's beast is something a day's task may ask for, and the
-- day's tasks are counted in COLUMNS (service/quests.go reads one per kind), so
-- a new kind is a new column here.
ALTER TABLE app.player_quests ADD COLUMN blows integer NOT NULL DEFAULT 0;

-- A war attack is two lords fighting, so it is an app.battles row like a raid
-- and an arena bout -- and a kind of its own, because none of what a raid does
-- happens in one: no gold moves, no shield is applied and none breaks.
ALTER TABLE app.battles DROP CONSTRAINT IF EXISTS battles_kind_check;
ALTER TABLE app.battles ADD CONSTRAINT battles_kind_check
    CHECK (kind IN ('raid', 'arena', 'bounty', 'war'));

-- The wave's own letters: a beast's chests and a war's purse. The kinds here
-- and the switch in service.checkDraft are the same list in two languages.
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board',
    'arena', 'bounty', 'throne', 'friend', 'goal', 'boss', 'war'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DELETE FROM app.mail WHERE kind IN ('boss', 'war');
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board',
    'arena', 'bounty', 'throne', 'friend', 'goal'));
ALTER TABLE app.battles DROP CONSTRAINT IF EXISTS battles_kind_check;
DELETE FROM app.battles WHERE kind = 'war';
ALTER TABLE app.battles ADD CONSTRAINT battles_kind_check
    CHECK (kind IN ('raid', 'arena', 'bounty'));
ALTER TABLE app.player_quests DROP COLUMN IF EXISTS blows;
DROP TABLE IF EXISTS app.war_attacks;
DROP TABLE IF EXISTS app.wars;
DROP TABLE IF EXISTS app.boss_hits;
DROP TABLE IF EXISTS app.kingdom_bosses;
-- +goose StatementEnd
