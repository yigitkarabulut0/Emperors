-- +goose Up
-- +goose StatementBegin

-- Where to reach a player who is not looking.
--
-- Energy is the only thing that pulls somebody back into this game, and its
-- cadence never changes across an 82-day climb. The design calls a revenge push
-- "the single highest-value retention mechanic in async PvP" and there is no way
-- to fire one: no token store, no APNs client, nothing.
--
-- This is the half that does not need Apple's approval to exist. A device
-- registers its token here; sending is a separate problem that needs an APNs
-- auth key and a Push Notifications capability on the App ID, neither of which
-- lives in this repository.
--
-- Keyed by the TOKEN, not the player: one person may carry two phones, and a
-- token can move between accounts when a device is handed on. Re-registering an
-- existing token re-points it, which is what makes a handover correct rather
-- than leaving the old owner's notifications going to the new one.
CREATE TABLE app.device_tokens (
    token       text        PRIMARY KEY,
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    platform    text        NOT NULL CHECK (platform IN ('ios', 'android')),
    -- Set when Apple tells us the token is dead. Kept rather than deleted so a
    -- device that comes back can be re-registered without losing the history of
    -- why it stopped.
    revoked_at  timestamptz,
    seen_at     timestamptz NOT NULL DEFAULT now(),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- "Where do I send this player's notification" — the only read that matters.
CREATE INDEX device_tokens_player_idx ON app.device_tokens (player_id)
    WHERE revoked_at IS NULL;

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.device_tokens;
