-- +goose Up
-- +goose StatementBegin

-- Live ops (liveops.json): the hourly event, the calendar's festivals, the
-- season and its Royal Charter, the boards that close with a week or a season,
-- and the deeds (achievements). Their rules are in the balance; this is what
-- each hour, festival, season and lord's place in them is.

-- ============================================================================
-- The hourly event
-- ============================================================================
-- Each hour's event is a keyed hash of the hour (game/liveops), so every server
-- agrees without asking. It is written down here the first time it is rolled,
-- so a balance published mid-hour cannot change an event already running, and
-- "what ran at 14:00 on the 3rd" is answerable. The panel forces or skips a
-- future hour by writing its row first ('forced', 'skipped').
CREATE TABLE admin.hourly_events (
    hour     bigint      PRIMARY KEY, -- Unix hours: seconds since the epoch / 3600
    event_id text        NOT NULL,    -- a row of liveops.hourly.table, 'none' for a quiet hour
    source   text        NOT NULL CHECK (source IN ('roll', 'forced', 'skipped')),
    set_by   text,
    set_at   timestamptz NOT NULL DEFAULT now(),
    note     text        NOT NULL DEFAULT ''
);

-- What a lord has used of an hour's event: the Royal Courier's gift claimed,
-- Fresh Wares' free rerolls taken. Kept two days, for the panel's questions.
CREATE TABLE app.player_hourly (
    player_id uuid     NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    hour      bigint   NOT NULL,
    used      smallint NOT NULL DEFAULT 0 CHECK (used >= 0),
    PRIMARY KEY (player_id, hour)
);
CREATE INDEX player_hourly_hour_idx ON app.player_hourly (hour);

-- ============================================================================
-- The calendar's festivals
-- ============================================================================
-- Scheduled from the panel off a template, and frozen as the template stood
-- then: a balance published during a festival changes nothing its lords are
-- already playing for. Never deleted: revoked, so its history stays readable.
-- One at a time (the service refuses an overlap).
CREATE TABLE admin.live_events (
    id          bigserial   PRIMARY KEY,
    template_id text        NOT NULL,
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    frozen      jsonb       NOT NULL,
    note        text        NOT NULL DEFAULT '',
    created_by  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at  timestamptz,
    revoked_by  text,
    -- The close has paid the board and sent what was left unclaimed.
    settled_at  timestamptz,
    CONSTRAINT live_events_window CHECK (ends_at > starts_at)
);
CREATE INDEX live_events_window_idx ON admin.live_events (starts_at, ends_at) WHERE revoked_at IS NULL;

-- A lord's festival: points in thousandths (a point for every two collects
-- keeps its halves), the festival day they were last earned on and what that
-- day has earned against the cap, and a bit per task and per milestone claimed.
-- Task progress is the festival's own deeds (app.player_deeds, scope 'event').
CREATE TABLE app.player_event (
    player_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    event_id     bigint      NOT NULL REFERENCES admin.live_events(id) ON DELETE CASCADE,
    points_milli bigint      NOT NULL DEFAULT 0 CHECK (points_milli >= 0),
    day          smallint    NOT NULL DEFAULT 0,
    day_milli    bigint      NOT NULL DEFAULT 0 CHECK (day_milli >= 0),
    -- When the points last rose: the board's tie-break (first there, first placed).
    points_at    timestamptz NOT NULL DEFAULT now(),
    tasks        integer     NOT NULL DEFAULT 0,
    milestones   integer     NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, event_id)
);
CREATE INDEX player_event_board_idx ON app.player_event (event_id, points_milli DESC, points_at);

-- ============================================================================
-- The season and its Royal Charter
-- ============================================================================
-- A season's number is arithmetic on the calendar (game/liveops.SeasonAt); a
-- lord's row in it is written the first time they earn or look. Points in
-- thousandths as for festivals; a bit per tier claimed in each lane (50 tiers:
-- a bigint's 63 bits hold them). royal_at is when the royal lane opened for this
-- season; royal_ref the App Store transaction that opened it, or null when it
-- was bought with diamonds -- what a refund finds.
CREATE TABLE app.player_season (
    player_id     uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    season        integer     NOT NULL CHECK (season >= 1),
    points_milli  bigint      NOT NULL DEFAULT 0 CHECK (points_milli >= 0),
    day           smallint    NOT NULL DEFAULT 0,
    day_milli     bigint      NOT NULL DEFAULT 0 CHECK (day_milli >= 0),
    points_at     timestamptz NOT NULL DEFAULT now(),
    free_claimed  bigint      NOT NULL DEFAULT 0,
    royal_claimed bigint      NOT NULL DEFAULT 0,
    royal_at      timestamptz,
    royal_ref     text,
    PRIMARY KEY (player_id, season)
);
CREATE INDEX player_season_board_idx ON app.player_season (season, points_milli DESC, points_at);

-- ============================================================================
-- Closes
-- ============================================================================
-- A week's board, a season's boards, its nobility and its leftovers: each paid
-- once when its period ends. Every letter a close sends carries an idempotency
-- key, so a close that died half way is simply run again; this row says it
-- finished, so the job stops looking.
CREATE TABLE admin.period_closes (
    what      text        NOT NULL,
    period    bigint      NOT NULL,
    closed_at timestamptz NOT NULL DEFAULT now(),
    lords     integer     NOT NULL DEFAULT 0,
    PRIMARY KEY (what, period)
);

-- ============================================================================
-- The deeds (achievements)
-- ============================================================================
-- Progress is a lifetime deed (app.player_deeds, scope 'life') or a stat read
-- off the lord's state; only the tiers claimed are kept.
CREATE TABLE app.player_achievements (
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    achievement text        NOT NULL,
    claimed     smallint    NOT NULL DEFAULT 0 CHECK (claimed BETWEEN 0 AND 4),
    claimed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, achievement)
);

-- ============================================================================
-- Boards with shared places
-- ============================================================================
-- A board counting raids has lords level with each other; they share the place
-- (and what it pays). rank stays the row's unique order; place is the number
-- shown and paid. The boards that existed rank without ties: place = rank.
ALTER TABLE app.leaderboard_entries ADD COLUMN place integer NOT NULL DEFAULT 0;
UPDATE app.leaderboard_entries SET place = rank;

-- The boards' letters.
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DELETE FROM app.mail WHERE kind = 'board';
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback'));
ALTER TABLE app.leaderboard_entries DROP COLUMN IF EXISTS place;
DROP TABLE IF EXISTS app.player_achievements;
DROP TABLE IF EXISTS admin.period_closes;
DROP TABLE IF EXISTS app.player_season;
DROP TABLE IF EXISTS app.player_event;
DROP TABLE IF EXISTS admin.live_events;
DROP TABLE IF EXISTS app.player_hourly;
DROP TABLE IF EXISTS admin.hourly_events;
-- +goose StatementEnd
