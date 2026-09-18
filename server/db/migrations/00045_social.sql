-- +goose Up
-- +goose StatementBegin

-- Sosyal (social.json): the kingdom's hall, the friends' roll and their gift,
-- the spyglass, the kingdom's aid and its shared goal. The rules are in the
-- balance; this is where each lord stands in them.
--
-- LOCKING ORDER, everywhere in this feature: app.players (ascending uuid),
-- then app.friends / app.gifts (by the pair, ascending), then app.kingdoms,
-- then app.kingdom_goals. Two friends gifting each other at the same instant
-- would otherwise deadlock, which is the same reason LockTwoPlayers orders by
-- id.
--
-- The aid's EFFECT has no table here: a stack is an ordinary row in
-- app.player_boosts with source 'aid', so it rides the timed lane every other
-- boost rides and is capped where they are capped. What is here is the CALL --
-- who asked and who answered -- because that is what the hall shows.

-- ============================================================================
-- The hall
-- ============================================================================
-- One row per line said in a kingdom. A line by a lord has a player_id; a line
-- the realm says has none and carries its kind (a lord joined, the treasury was
-- opened, a boss fell) plus whatever the client needs to draw its plate.
--
-- body is what the lord actually typed and shown is what the hall displays:
-- masking at read time would let a change to the word list quietly re-write
-- what was said, and the moderation queue has to read the words themselves.
--
-- seq is the room's clock. It is global rather than per-kingdom because a
-- single sequence is the one thing two rooms cannot disagree about, and the
-- client only ever asks for "after seq" inside its own room.
CREATE TABLE app.chat_messages (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    seq         bigserial   NOT NULL,
    kingdom_id  uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    player_id   uuid        REFERENCES app.players(id) ON DELETE SET NULL,
    -- 'lord' is somebody speaking; 'system' is the realm.
    kind        text        NOT NULL CHECK (kind IN ('lord', 'system')),
    system_kind text,
    body        text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 500),
    shown       text        NOT NULL CHECK (char_length(shown) BETWEEN 1 AND 500),
    payload     jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- Hidden by three reports, or by the crown. A hidden line is kept: the
    -- queue reads it, and a line deleted the moment it is reported is a line
    -- no moderator can judge.
    hidden_at   timestamptz,
    hidden_by   text,
    reports     smallint    NOT NULL DEFAULT 0 CHECK (reports >= 0),
    CONSTRAINT chat_system_has_no_lord CHECK (
        (kind = 'lord'   AND player_id IS NOT NULL AND system_kind IS NULL) OR
        (kind = 'system' AND system_kind IS NOT NULL)
    )
);
-- The room, newest first: the only way the hall is ever read.
CREATE UNIQUE INDEX chat_room_seq_idx ON app.chat_messages (kingdom_id, seq DESC);
-- The sweeper, and the queue's "what else did this lord say".
CREATE INDEX chat_created_idx ON app.chat_messages (created_at);
CREATE INDEX chat_author_idx ON app.chat_messages (player_id, created_at DESC) WHERE player_id IS NOT NULL;
-- The moderation queue: what is reported and not yet judged, oldest first (the
-- SLA is measured from the first report).
CREATE INDEX chat_queue_idx ON app.chat_messages (created_at) WHERE reports > 0;

-- Who reported what. One report per lord per line, and the count on the line
-- is what hides it -- three lords, not one, so no lord can silence another.
CREATE TABLE app.chat_reports (
    message_id  uuid        NOT NULL REFERENCES app.chat_messages(id) ON DELETE CASCADE,
    reporter_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    reason      text        NOT NULL CHECK (reason IN ('abuse', 'hate', 'spam', 'private', 'other')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, reporter_id)
);

-- Every silence, and who ordered it. The LIVE guard is
-- app.players.chat_muted_until, read from the row the send has already locked;
-- this is the trail the panel shows, and the two are written together.
CREATE TABLE app.chat_mutes (
    id         bigserial   PRIMARY KEY,
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    until      timestamptz NOT NULL,
    reason     text        NOT NULL,
    -- 'auto' for the three strikes, an admin's username otherwise.
    by_whom    text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_mutes_player_idx ON app.chat_mutes (player_id, created_at DESC);

-- A lord this lord will not hear from, anywhere: the hall, a request, a
-- profile, a spyglass. One way, and never visible to the blocked lord.
CREATE TABLE app.blocks (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    blocked_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, blocked_id),
    CONSTRAINT blocks_not_self CHECK (player_id <> blocked_id)
);
-- "Does either of us block the other", which every social answer asks.
CREATE INDEX blocks_reverse_idx ON app.blocks (blocked_id, player_id);

-- ============================================================================
-- Friends
-- ============================================================================
-- One row per friendship, the pair always in id order: two rows would be two
-- truths, and the day they disagreed one lord would see a friend the other did
-- not. Listing reads "a = me OR b = me", which the two indexes below carry.
CREATE TABLE app.friends (
    a     uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    b     uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    since timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (a, b),
    CONSTRAINT friends_ordered CHECK (a < b)
);
CREATE INDEX friends_b_idx ON app.friends (b, a);

-- A request waiting to be answered. It disappears the moment it is accepted
-- (into app.friends) or declined.
CREATE TABLE app.friend_requests (
    from_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    to_id      uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (from_id, to_id),
    CONSTRAINT friend_requests_not_self CHECK (from_id <> to_id)
);
CREATE INDEX friend_requests_to_idx ON app.friend_requests (to_id, created_at DESC);

-- A gift sent, and the day it was sent on. One a day to each friend is the
-- primary key itself, in the SENDER's local day: a gift is a kindness at the
-- sender's breakfast, not at the server's midnight.
--
-- token is the FLASK the gift carries (social.friends.gift_token). What it is
-- worth is resolved when it is TAKEN, from the taker's own pool, because that
-- is what a flask has always been in this game -- and it is stored per row so
-- that a balance which one day sends a bigger draught does not change what was
-- already promised.
CREATE TABLE app.gifts (
    from_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    to_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    sent_on  date        NOT NULL,
    token    text        NOT NULL,
    sent_at  timestamptz NOT NULL DEFAULT now(),
    taken_at timestamptz,
    PRIMARY KEY (from_id, to_id, sent_on),
    CONSTRAINT gifts_not_self CHECK (from_id <> to_id)
);
-- What is waiting for me, oldest first.
CREATE INDEX gifts_waiting_idx ON app.gifts (to_id, sent_at) WHERE taken_at IS NULL;

-- ============================================================================
-- The spyglass
-- ============================================================================
-- An hour's look at a rival's army, bought with gold. The report is FROZEN at
-- the moment it was bought: an army that changed since is exactly what the
-- rival hopes you are looking at.
--
-- The target is told. scouted_at on the report is what the rival's own tab
-- counts, so a lord always knows they were looked at, which is what keeps this
-- a move in a game rather than a camera.
CREATE TABLE app.spy_reports (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    viewer_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    target_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    cost       bigint      NOT NULL CHECK (cost >= 0),
    report     jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT spy_not_self CHECK (viewer_id <> target_id),
    CONSTRAINT spy_window CHECK (expires_at > created_at)
);
-- "What am I still holding on this lord", and "who has been watching me today".
CREATE UNIQUE INDEX spy_live_idx ON app.spy_reports (viewer_id, target_id, created_at DESC);
CREATE INDEX spy_target_idx ON app.spy_reports (target_id, created_at DESC);

-- ============================================================================
-- The kingdom's aid
-- ============================================================================
-- A call for help, and who answered it. The call stands for its window; the
-- stacks it earns are ordinary rows in app.player_boosts (source 'aid').
CREATE TABLE app.kingdom_aid (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kingdom_id uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    asker_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    answers    smallint    NOT NULL DEFAULT 0 CHECK (answers >= 0),
    CONSTRAINT aid_window CHECK (expires_at > created_at)
);
-- The hall's list: the calls still standing in this kingdom, newest first.
CREATE INDEX kingdom_aid_open_idx ON app.kingdom_aid (kingdom_id, expires_at DESC);

CREATE TABLE app.kingdom_aid_answers (
    aid_id    uuid        NOT NULL REFERENCES app.kingdom_aid(id) ON DELETE CASCADE,
    helper_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (aid_id, helper_id)
);

-- ============================================================================
-- The shared goal
-- ============================================================================
-- One goal a day for a kingdom. target is frozen when the goal is set, from
-- the members it had then: a kingdom that doubles overnight does not double
-- its bar, and one that empties does not keep a bar nobody can reach.
--
-- The day is the KINGDOM's (UTC), not each lord's: a shared goal with thirty
-- different midnights in it is not shared.
CREATE TABLE app.kingdom_goals (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kingdom_id  uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    day         date        NOT NULL,
    kind        text        NOT NULL,
    target      bigint      NOT NULL CHECK (target > 0),
    progress    bigint      NOT NULL DEFAULT 0 CHECK (progress >= 0),
    members     smallint    NOT NULL CHECK (members > 0),
    started_at  timestamptz NOT NULL DEFAULT now(),
    ends_at     timestamptz NOT NULL,
    claim_until timestamptz NOT NULL,
    CONSTRAINT goal_one_a_day UNIQUE (kingdom_id, day),
    CONSTRAINT goal_window CHECK (ends_at > started_at AND claim_until >= ends_at)
);
CREATE INDEX kingdom_goals_live_idx ON app.kingdom_goals (kingdom_id, day DESC);

-- What each lord put in, and which chests they have taken. A lord who joined
-- after the goal began has no row here and so can claim nothing: that is the
-- kingdom-hopping guard, and it needs no clock of its own.
CREATE TABLE app.kingdom_goal_parts (
    goal_id   uuid     NOT NULL REFERENCES app.kingdom_goals(id) ON DELETE CASCADE,
    player_id uuid     NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    amount    bigint   NOT NULL DEFAULT 0 CHECK (amount >= 0),
    -- A bit per chest taken, so a claim is idempotent and a repeat pays nothing.
    claimed   smallint NOT NULL DEFAULT 0 CHECK (claimed >= 0),
    PRIMARY KEY (goal_id, player_id)
);

-- ============================================================================
-- What a lord carries
-- ============================================================================
-- The day's counters sit on the player row, beside refills_day and
-- arena_day, because every one of them is a guard that must be read from the
-- row the action has already locked, in the same statement that spends it.
ALTER TABLE app.players
    ADD COLUMN chat_muted_until   timestamptz,
    ADD COLUMN chat_strikes       smallint    NOT NULL DEFAULT 0 CHECK (chat_strikes >= 0),
    ADD COLUMN chat_strike_at     timestamptz,
    -- The rules version this lord agreed to. 0 is a lord who has not.
    ADD COLUMN chat_rules_version smallint    NOT NULL DEFAULT 0 CHECK (chat_rules_version >= 0),
    -- The last line they have seen in their own hall, for the tab's dot.
    ADD COLUMN chat_seen_seq      bigint      NOT NULL DEFAULT 0 CHECK (chat_seen_seq >= 0),
    -- The day's take of gifts: three a day, counted here beside every other
    -- day's counter, because the guard must be read from the row the take has
    -- already locked.
    ADD COLUMN gift_day           date,
    ADD COLUMN gifts_taken        smallint    NOT NULL DEFAULT 0 CHECK (gifts_taken >= 0),
    ADD COLUMN friend_req_day     date,
    ADD COLUMN friend_reqs        smallint    NOT NULL DEFAULT 0 CHECK (friend_reqs >= 0),
    ADD COLUMN spy_day            date,
    ADD COLUMN spy_used           smallint    NOT NULL DEFAULT 0 CHECK (spy_used >= 0),
    ADD COLUMN aid_day            date,
    ADD COLUMN aid_given          smallint    NOT NULL DEFAULT 0 CHECK (aid_given >= 0),
    ADD COLUMN aid_asked_at       timestamptz,
    -- The settings page. Each is a column rather than a document: a jsonb of
    -- preferences is a place for a typo to live, and every one of these is
    -- read by the server before it sends anything.
    ADD COLUMN notif_raid         boolean     NOT NULL DEFAULT true,
    ADD COLUMN notif_chat         boolean     NOT NULL DEFAULT true,
    ADD COLUMN notif_mail         boolean     NOT NULL DEFAULT true,
    ADD COLUMN notif_events       boolean     NOT NULL DEFAULT true,
    ADD COLUMN notif_friends      boolean     NOT NULL DEFAULT true,
    -- Quiet hours in the lord's OWN day, as two hours of the clock. Equal
    -- means no quiet hours at all; from > to wraps around midnight, which is
    -- the usual case (22 to 8).
    ADD COLUMN quiet_from         smallint    NOT NULL DEFAULT 0 CHECK (quiet_from BETWEEN 0 AND 23),
    ADD COLUMN quiet_to           smallint    NOT NULL DEFAULT 0 CHECK (quiet_to BETWEEN 0 AND 23),
    -- Who may look at this lord's page, and whether the friends' strip shows
    -- them as here. 'all' is the default because every profile in this game is
    -- already public on a leaderboard.
    ADD COLUMN privacy_profile    text        NOT NULL DEFAULT 'all'
        CHECK (privacy_profile IN ('all', 'friends', 'kingdom')),
    ADD COLUMN privacy_online     boolean     NOT NULL DEFAULT true,
    ADD COLUMN privacy_requests   boolean     NOT NULL DEFAULT true;

-- The hall's own letters: a gift taken and a goal's chest. The kinds here and
-- the switch in service.checkDraft are the same list in two languages.
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board',
    'arena', 'bounty', 'throne', 'friend', 'goal'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DELETE FROM app.mail WHERE kind IN ('friend', 'goal');
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback', 'board',
    'arena', 'bounty', 'throne'));
DELETE FROM app.player_boosts WHERE source = 'aid';
ALTER TABLE app.players
    DROP COLUMN IF EXISTS privacy_requests,
    DROP COLUMN IF EXISTS privacy_online,
    DROP COLUMN IF EXISTS privacy_profile,
    DROP COLUMN IF EXISTS quiet_to,
    DROP COLUMN IF EXISTS quiet_from,
    DROP COLUMN IF EXISTS notif_friends,
    DROP COLUMN IF EXISTS notif_events,
    DROP COLUMN IF EXISTS notif_mail,
    DROP COLUMN IF EXISTS notif_chat,
    DROP COLUMN IF EXISTS notif_raid,
    DROP COLUMN IF EXISTS aid_asked_at,
    DROP COLUMN IF EXISTS aid_given,
    DROP COLUMN IF EXISTS aid_day,
    DROP COLUMN IF EXISTS spy_used,
    DROP COLUMN IF EXISTS spy_day,
    DROP COLUMN IF EXISTS friend_reqs,
    DROP COLUMN IF EXISTS friend_req_day,
    DROP COLUMN IF EXISTS gifts_taken,
    DROP COLUMN IF EXISTS gift_day,
    DROP COLUMN IF EXISTS chat_seen_seq,
    DROP COLUMN IF EXISTS chat_rules_version,
    DROP COLUMN IF EXISTS chat_strike_at,
    DROP COLUMN IF EXISTS chat_strikes,
    DROP COLUMN IF EXISTS chat_muted_until;
DROP TABLE IF EXISTS app.kingdom_goal_parts;
DROP TABLE IF EXISTS app.kingdom_goals;
DROP TABLE IF EXISTS app.kingdom_aid_answers;
DROP TABLE IF EXISTS app.kingdom_aid;
DROP TABLE IF EXISTS app.spy_reports;
DROP TABLE IF EXISTS app.gifts;
DROP TABLE IF EXISTS app.friend_requests;
DROP TABLE IF EXISTS app.friends;
DROP TABLE IF EXISTS app.blocks;
DROP TABLE IF EXISTS app.chat_mutes;
DROP TABLE IF EXISTS app.chat_reports;
DROP TABLE IF EXISTS app.chat_messages;
-- +goose StatementEnd
