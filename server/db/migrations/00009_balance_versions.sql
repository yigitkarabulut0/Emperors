-- +goose Up
-- +goose StatementBegin

CREATE SCHEMA IF NOT EXISTS admin;

-- ============================================================================
-- Versioned balance documents
-- ============================================================================
-- The document is stored as TEXT, not jsonb, and that is deliberate. jsonb
-- normalises key order and whitespace, so sha256 over the bytes that went in
-- would not match sha256 over the bytes that come back and the seal would be
-- worthless. A generated jsonb column gives querying without touching the
-- sealed bytes.
CREATE TABLE admin.balance_versions (
    id          bigserial   PRIMARY KEY,
    doc         text        NOT NULL,
    doc_json    jsonb       GENERATED ALWAYS AS (doc::jsonb) STORED,
    sha256      bytea       NOT NULL,
    note        text        NOT NULL DEFAULT '',
    created_by  text        NOT NULL DEFAULT 'system',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX balance_versions_created_idx ON admin.balance_versions (created_at DESC);

-- Append-only. The newest row IS the live configuration, so a rollback is
-- another activation rather than an edit, and the history of what was live when
-- survives intact — which is the only way to explain an old battle or an old
-- item roll after a rebalance.
CREATE TABLE admin.balance_activations (
    id           bigserial   PRIMARY KEY,
    version_id   bigint      NOT NULL REFERENCES admin.balance_versions(id),
    activated_by text        NOT NULL DEFAULT 'system',
    reason       text        NOT NULL DEFAULT '',
    activated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX balance_activations_at_idx ON admin.balance_activations (activated_at DESC);

-- ============================================================================
-- Admin identities and the audit trail
-- ============================================================================
CREATE TABLE admin.users (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    username      text        NOT NULL,
    password_hash text        NOT NULL,
    role          text        NOT NULL DEFAULT 'analyst'
                              CHECK (role IN ('owner','designer','moderator','analyst')),
    disabled      boolean     NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz
);
CREATE UNIQUE INDEX admin_users_username_key ON admin.users (lower(username));

CREATE TABLE admin.sessions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id   uuid        NOT NULL REFERENCES admin.users(id) ON DELETE CASCADE,
    token_hash bytea       NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX admin_sessions_token_key ON admin.sessions (token_hash);

-- Every admin action, with what it looked like before and after. An admin panel
-- can grant currency and ban accounts; without this there is no way to answer
-- "who did this and why" three months later.
CREATE TABLE admin.audit_log (
    id         bigserial   PRIMARY KEY,
    admin_id   uuid        REFERENCES admin.users(id) ON DELETE SET NULL,
    admin_name text        NOT NULL,
    action     text        NOT NULL,
    subject    text,
    before     jsonb,
    after      jsonb,
    note       text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_created_idx ON admin.audit_log (created_at DESC);
CREATE INDEX audit_log_subject_idx ON admin.audit_log (subject, created_at DESC);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS admin.audit_log;
DROP TABLE IF EXISTS admin.sessions;
DROP TABLE IF EXISTS admin.users;
DROP TABLE IF EXISTS admin.balance_activations;
DROP TABLE IF EXISTS admin.balance_versions;
DROP SCHEMA IF EXISTS admin;
