-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- Deleted accounts
-- ============================================================================
-- Deleting an account removes the lord and everything they own (Guideline
-- 5.1.1(v)). What must outlive them has no foreign key: the diamond ledger
-- (00027) and, with purchases, the App Store's transactions. Apple can refund a
-- purchase weeks after the buyer deleted their lord, and the notification names
-- only the account's id. This table is how that id is told apart from one that
-- never existed: a refund for a deleted account is settled as "nothing left to
-- take back", not investigated as an unknown buyer.
--
-- Nothing personal is kept -- no name, no device, no identity -- only the id,
-- when it joined and left, and what it held on the way out. The diamond ledger
-- for a deleted account is purged 90 days after this row is written
-- (deleted_ledger_purge); these rows stay, because a refund can come later.
CREATE TABLE app.deleted_accounts (
    player_id    uuid        PRIMARY KEY,
    joined_at    timestamptz NOT NULL,
    deleted_at   timestamptz NOT NULL,
    level        integer     NOT NULL,
    diamonds     bigint      NOT NULL,
    diamond_debt bigint      NOT NULL
);
CREATE INDEX deleted_accounts_deleted_at_idx ON app.deleted_accounts (deleted_at);

-- ============================================================================
-- Player days: who played on which day
-- ============================================================================
-- last_seen_at is one timestamp per player, so it can say who was here today
-- but never who was here last Tuesday: the "active" series counted each player
-- only on the day they were LAST seen, and a player who came every day showed
-- up once. Retention (did the players who joined on the 3rd come back on the
-- 4th, the 10th, the 2nd of next month?) cannot be answered from it at all.
--
-- One row per player per UTC day they sent any authenticated request, written by
-- the presence flush in the same statement as last_seen_at. No foreign key: a
-- deleted player's days still happened, and a cohort that loses its members
-- when they leave would report retention too high.
CREATE TABLE app.player_days (
    player_id uuid NOT NULL,
    day       date NOT NULL,
    PRIMARY KEY (player_id, day)
);
CREATE INDEX player_days_day_idx ON app.player_days (day);

-- What can be recovered of the past: the day each player joined and the day
-- they were last seen. Everything between is gone; the series is exact from
-- the day this migration runs.
INSERT INTO app.player_days (player_id, day)
SELECT id, (created_at AT TIME ZONE 'UTC')::date FROM app.players WHERE NOT is_bot
UNION
SELECT id, (last_seen_at AT TIME ZONE 'UTC')::date FROM app.players WHERE NOT is_bot;

-- ============================================================================
-- Analytics events: what only the phone can see
-- ============================================================================
-- The server knows every action; it cannot know which screen was open, how long
-- a session lasted, or where a player turned back. The client reports those
-- here, through POST /v1/events, and only under names the server has listed
-- (service/events.go): a name or a property not on the list is dropped, so the
-- table holds what someone decided to measure and never free text.
--
-- No foreign key, so a count over a past week does not change when a player
-- leaves; a deleted account's events are removed with it (DeleteAccount), and
-- everything is purged after 180 days (analytics_purge).
CREATE TABLE app.analytics_events (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  uuid        NOT NULL,
    name       text        NOT NULL,
    props      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- The phone's clock when it happened, if it was believable; the server's
    -- when it arrived is created_at.
    client_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- The panel's counts over a window, by name.
CREATE INDEX analytics_events_name_idx ON app.analytics_events (name, created_at);
-- The hourly allowance per player, and deleting one player's events.
CREATE INDEX analytics_events_player_idx ON app.analytics_events (player_id, created_at);
-- The purge.
CREATE INDEX analytics_events_created_idx ON app.analytics_events (created_at);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.analytics_events;
DROP TABLE IF EXISTS app.player_days;
DROP TABLE IF EXISTS app.deleted_accounts;
-- +goose StatementEnd
