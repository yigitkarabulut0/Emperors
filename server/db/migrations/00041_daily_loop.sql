-- +goose Up
-- +goose StatementBegin

-- The daily loop (retention.json): the Tax Cart, the 28-day calendar, the
-- week's quests, the Golden Hour, the Victory Road, the steward's guide and the
-- welcome back. Their rules are in the balance; this is only what each lord's
-- place in them is.

-- The Tax Cart: carts waiting, and the clock the next one is counted from
-- (game/cart: while the yard is full the clock waits). Every lord's gate starts
-- with one cart waiting, a new lord's as well as an old one's.
ALTER TABLE app.players
    ADD COLUMN cart_stock   smallint    NOT NULL DEFAULT 1 CHECK (cart_stock >= 0),
    ADD COLUMN cart_at      timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN carts_opened integer     NOT NULL DEFAULT 0 CHECK (carts_opened >= 0);

-- The 28-day calendar: squares claimed in this cycle, and cycles finished. The
-- run a lord already had is carried: their streak's place on the new calendar.
-- The run's own rules (a missed day breaks it) read daily_claimed_on as ever.
ALTER TABLE app.players
    ADD COLUMN calendar_pos   smallint NOT NULL DEFAULT 0 CHECK (calendar_pos BETWEEN 0 AND 28),
    ADD COLUMN calendar_cycle integer  NOT NULL DEFAULT 0 CHECK (calendar_cycle >= 0);
UPDATE app.players
SET calendar_pos = CASE WHEN daily_streak <= 0 THEN 0 ELSE ((daily_streak - 1) % 28) + 1 END;

-- A Royal Pardon each, for the cycle every lord is already part-way through (a
-- new lord is given theirs with the first square).
INSERT INTO app.player_tokens (player_id, token, qty)
SELECT id, 'pardon', 1 FROM app.players WHERE NOT is_bot
ON CONFLICT (player_id, token) DO NOTHING;

-- The week's quests: the board a lord's week drew (frozen at the week's first
-- look, as the day's quests are), which tasks and chests are claimed (a bit per
-- slot), and the points claimed tasks have earned. Progress is the week's
-- deeds (app.player_deeds, scope 'week'); nothing here counts.
CREATE TABLE app.player_weekly (
    player_id uuid    NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    week      date    NOT NULL,
    task_ids  text[]  NOT NULL,
    claimed   integer NOT NULL DEFAULT 0,
    chests    integer NOT NULL DEFAULT 0,
    points    integer NOT NULL DEFAULT 0 CHECK (points >= 0),
    PRIMARY KEY (player_id, week)
);

-- The Golden Hour (game/frenzy): the run's meter and its last collect, the
-- hour's end and the energy it may still cover, the day's count and when the
-- next may light.
ALTER TABLE app.players
    ADD COLUMN frenzy_meter_milli bigint      NOT NULL DEFAULT 0 CHECK (frenzy_meter_milli >= 0),
    ADD COLUMN frenzy_last_at     timestamptz,
    ADD COLUMN frenzy_until       timestamptz,
    ADD COLUMN frenzy_energy_left bigint      NOT NULL DEFAULT 0 CHECK (frenzy_energy_left >= 0),
    ADD COLUMN frenzy_day         date,
    ADD COLUMN frenzy_used        smallint    NOT NULL DEFAULT 0 CHECK (frenzy_used >= 0),
    ADD COLUMN frenzy_ready_at    timestamptz;

-- The Victory Road: a bit per milestone claimed.
ALTER TABLE app.players ADD COLUMN road_claimed integer NOT NULL DEFAULT 0;

-- The steward's guide: the step a new lord is on, and when it ended (finished
-- or skipped). Every lord who exists already knows the realm: their guide is
-- over before it began, without its reward.
ALTER TABLE app.players
    ADD COLUMN guide_step    smallint NOT NULL DEFAULT 0 CHECK (guide_step >= 0),
    ADD COLUMN guide_done_at timestamptz,
    ADD COLUMN guide_skipped boolean  NOT NULL DEFAULT false;
UPDATE app.players SET guide_done_at = now();

-- Welcome back: when the last letter was sent, and which (1 the welcome, 2 the
-- long absence's diamonds too) -- for the absence it answered.
ALTER TABLE app.players
    ADD COLUMN winback_at   timestamptz,
    ADD COLUMN winback_tier smallint NOT NULL DEFAULT 0 CHECK (winback_tier BETWEEN 0 AND 2);
CREATE INDEX players_away_idx ON app.players (last_seen_at) WHERE NOT is_bot;

-- A Tax Cart's Lucky Charm is a timed luck bonus owned by one lord.
ALTER TABLE app.player_boosts DROP CONSTRAINT IF EXISTS player_boosts_bucket_check;
ALTER TABLE app.player_boosts ADD CONSTRAINT player_boosts_bucket_check
    CHECK (bucket IN ('collect_income_bp', 'xp_bp', 'luck_bp'));

-- The welcome-back letter.
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season', 'winback'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.mail DROP CONSTRAINT IF EXISTS mail_kind_check;
ALTER TABLE app.mail ADD CONSTRAINT mail_kind_check CHECK (kind IN (
    'system', 'admin', 'compensation', 'gift', 'largesse', 'referral',
    'promo', 'purchase', 'kingdom', 'event', 'season'));
ALTER TABLE app.player_boosts DROP CONSTRAINT IF EXISTS player_boosts_bucket_check;
ALTER TABLE app.player_boosts ADD CONSTRAINT player_boosts_bucket_check
    CHECK (bucket IN ('collect_income_bp', 'xp_bp'));
DROP INDEX IF EXISTS app.players_away_idx;
ALTER TABLE app.players
    DROP COLUMN IF EXISTS winback_tier,
    DROP COLUMN IF EXISTS winback_at,
    DROP COLUMN IF EXISTS guide_skipped,
    DROP COLUMN IF EXISTS guide_done_at,
    DROP COLUMN IF EXISTS guide_step,
    DROP COLUMN IF EXISTS road_claimed,
    DROP COLUMN IF EXISTS frenzy_ready_at,
    DROP COLUMN IF EXISTS frenzy_used,
    DROP COLUMN IF EXISTS frenzy_day,
    DROP COLUMN IF EXISTS frenzy_energy_left,
    DROP COLUMN IF EXISTS frenzy_until,
    DROP COLUMN IF EXISTS frenzy_last_at,
    DROP COLUMN IF EXISTS frenzy_meter_milli,
    DROP COLUMN IF EXISTS calendar_cycle,
    DROP COLUMN IF EXISTS calendar_pos,
    DROP COLUMN IF EXISTS carts_opened,
    DROP COLUMN IF EXISTS cart_at,
    DROP COLUMN IF EXISTS cart_stock;
DROP TABLE IF EXISTS app.player_weekly;
DELETE FROM app.player_tokens WHERE token = 'pardon';
-- +goose StatementEnd
