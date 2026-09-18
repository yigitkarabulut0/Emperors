-- +goose Up
-- +goose StatementBegin

-- A LORD REPORTED, not a line.
--
-- app.chat_reports answers "this line should not stand". It cannot answer the
-- other half of what a game with talking in it has to offer (App Review 1.2):
-- a way to report the PERSON -- a name nobody should have to read, a face they
-- wear, a lord who is cheating -- where there is no line to point at, and
-- where the complaint is about the lord and not one thing they said.
--
-- The rival's page (rival.png) has the button painted on it; this is where it
-- goes. One row per reporter per lord per reason: reporting twice is not
-- twice as true, and an unresolved report from the same lord is not counted
-- again.
CREATE TABLE app.lord_reports (
    id          bigserial   PRIMARY KEY,
    target_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    reporter_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    reason      text        NOT NULL CHECK (reason IN ('name', 'look', 'chat', 'cheat', 'other')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- Set when the desk has judged it, with the moderator's name beside it: a
    -- report nobody answered and a report answered "nothing to do" must not
    -- read the same in the queue.
    resolved_at timestamptz,
    resolved_by text
);

-- The queue reads the unresolved ones, newest first, and counts them per lord.
CREATE INDEX lord_reports_open_idx ON app.lord_reports (created_at DESC)
    WHERE resolved_at IS NULL;
CREATE INDEX lord_reports_target_idx ON app.lord_reports (target_id, created_at DESC);
-- One open report per reporter per lord per reason.
CREATE UNIQUE INDEX lord_reports_once_idx ON app.lord_reports (target_id, reporter_id, reason)
    WHERE resolved_at IS NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.lord_reports;
-- +goose StatementEnd
