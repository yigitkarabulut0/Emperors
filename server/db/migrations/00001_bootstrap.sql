-- +goose Up
-- The app schema keeps game tables out of `public`, which keeps Neon's own
-- objects and any extension's objects from colliding with ours.
CREATE SCHEMA IF NOT EXISTS app;

-- server_info exists so milestone M0 has something real to read: a value that
-- can only be on the phone's screen if the whole pipe works.
CREATE TABLE app.server_info (
    key        text PRIMARY KEY,
    value      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO app.server_info (key, value) VALUES
    ('motto',         'Rise, and let the realm remember your name.'),
    ('schema_owner',  'emperors');

-- +goose Down
DROP TABLE IF EXISTS app.server_info;
DROP SCHEMA IF EXISTS app;
