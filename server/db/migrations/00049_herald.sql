-- +goose Up
-- +goose StatementBegin

-- HERALD'S TIDINGS -- the rewarded advert (store.png's herald).
--
-- A watch is a TICKET before it is a reward. The client is handed one when it
-- starts an advert; the SDK carries it to Google as `custom_data`; and it is
-- GOOGLE'S CALLBACK, signed with a key of theirs, that turns it into diamonds.
-- The client never says "I watched it", because a client that could say that
-- could say it a hundred times.
--
-- So the row exists from the tap, and is paid at most once if and when the
-- callback comes. The unique index on Google's own transaction id is what makes
-- "at most once" true however many times they retry.
CREATE TABLE app.ad_watches (
    -- The ticket itself: what the SDK carries and what the callback names.
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    -- Which advert unit it was started against, kept so a second placement can
    -- be told from the first without reading the balance of the day it ran.
    unit       text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- A watch that has not come back by here never will: Google's retries are
    -- measured in minutes, not days.
    expires_at timestamptz NOT NULL,

    -- What the callback said, once it came. Null while a watch is unfinished,
    -- which is also what "this lord has one in flight" means.
    transaction_id text,
    paid_at        timestamptz,
    diamonds       bigint      NOT NULL DEFAULT 0,
    -- Which of Google's keys signed it, so a log can explain a rotation.
    key_id         bigint
);

-- One payment per watch, whatever Google's retries do.
CREATE UNIQUE INDEX ad_watches_transaction_idx ON app.ad_watches (transaction_id)
    WHERE transaction_id IS NOT NULL;
-- The day's allowance, the cooldown and "is one in flight" are all counted from
-- these rows: there is no counter on the player to drift from them.
CREATE INDEX ad_watches_player_idx ON app.ad_watches (player_id, created_at DESC);
CREATE INDEX ad_watches_unpaid_idx ON app.ad_watches (expires_at) WHERE paid_at IS NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.ad_watches;
-- +goose StatementEnd
