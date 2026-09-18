-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- The Royal Mail
-- ============================================================================
-- The one way the game hands a player something outside an action they took: a
-- compensation after an outage, a gift from the Crown, the rewards of a season
-- or an event that closed while they were away, a kingdom's largesse. Letters
-- carry a reward bundle (gameconfig.RewardBundle) as their attachments, and
-- claiming one pays it through the same grant every other reward uses.

-- A letter sent to many at once, from the admin panel.
--
-- 'all' is delivered LAZILY: nothing is written for a hundred thousand players
-- at send time. Each player's own copy is created the next time they look (the
-- inbox, or the heartbeat's badge), which is also why a lord who never comes
-- back never costs a row. 'segment' and 'player' sends are written at once --
-- their audience is known and bounded -- and are kept here only for history
-- and revoking.
CREATE TABLE admin.mail_broadcasts (
    id          bigserial   PRIMARY KEY,
    audience    text        NOT NULL CHECK (audience IN ('all', 'segment', 'player')),
    segment     jsonb       NOT NULL DEFAULT '{}',
    sender      text        NOT NULL DEFAULT 'The Crown',
    title       text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
    body        text        NOT NULL DEFAULT '' CHECK (char_length(body) <= 2000),
    attachments jsonb       NOT NULL DEFAULT '{}',
    -- Whether lords who arrive AFTER an 'all' letter was sent receive it too.
    include_new boolean     NOT NULL DEFAULT false,
    expires_at  timestamptz NOT NULL,
    sent_count  integer     NOT NULL DEFAULT 0,
    created_by  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at  timestamptz,
    revoked_by  text,
    note        text        NOT NULL DEFAULT ''
);
CREATE INDEX mail_broadcasts_live_idx ON admin.mail_broadcasts (id)
    WHERE audience = 'all' AND revoked_at IS NULL;

-- One player's letter.
CREATE TABLE app.mail (
    id           bigserial   PRIMARY KEY,
    player_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    kind         text        NOT NULL CHECK (kind IN (
                     'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
                     'promo', 'purchase', 'kingdom', 'event', 'season')),
    sender       text        NOT NULL DEFAULT 'The Crown',
    title        text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
    body         text        NOT NULL DEFAULT '' CHECK (char_length(body) <= 2000),
    attachments  jsonb       NOT NULL DEFAULT '{}',
    -- Makes every system sender idempotent: a job that sends "the season's
    -- rewards" twice, or a retry after a timeout, delivers one letter.
    idem_key     text,
    broadcast_id bigint      REFERENCES admin.mail_broadcasts(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    read_at      timestamptz,
    claimed_at   timestamptz,
    deleted_at   timestamptz,
    CONSTRAINT mail_expiry CHECK (expires_at > created_at)
);
CREATE UNIQUE INDEX mail_idem_uq ON app.mail (player_id, idem_key) WHERE idem_key IS NOT NULL;
CREATE INDEX mail_inbox_idx ON app.mail (player_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX mail_broadcast_idx ON app.mail (broadcast_id) WHERE broadcast_id IS NOT NULL;

-- The newest 'all' letter this player has been given their copy of. A letter
-- with a higher id is theirs to materialise on their next look.
ALTER TABLE app.players ADD COLUMN mail_bc_seen bigint NOT NULL DEFAULT 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players DROP COLUMN IF EXISTS mail_bc_seen;
DROP TABLE IF EXISTS app.mail;
DROP TABLE IF EXISTS admin.mail_broadcasts;
-- +goose StatementEnd
