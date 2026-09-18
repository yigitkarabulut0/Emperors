-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- The phones a lord plays on
-- ============================================================================
-- A keyed hash of the phone's own identifier (identifierForVendor on iOS), never
-- the identifier itself: enough to say "these two accounts share a phone", and
-- useless to anyone who reads the table. Written at sign-in and whenever a
-- promo code or a friend's code is entered. No foreign key: it outlives an
-- account for the same reason purchases do, so a deleted account's phone still
-- cannot redeem a code twice.
CREATE TABLE app.player_devices (
    player_id   uuid        NOT NULL,
    device_hash text        NOT NULL,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, device_hash)
);
CREATE INDEX player_devices_hash_idx ON app.player_devices (device_hash);

-- ============================================================================
-- Promo codes
-- ============================================================================
-- Made in the panel. A code's reward is a RewardBundle with no cosmetics and a
-- handful of diamonds at most (admin/promo.go checks it against the balance);
-- it arrives as a Royal Mail letter.
CREATE TABLE admin.promo_codes (
    code        text        PRIMARY KEY CHECK (code ~ '^[A-Z0-9]{4,20}$'),
    note        text        NOT NULL DEFAULT '',
    reward      jsonb       NOT NULL,
    -- How many lords may redeem it; 0 is no limit.
    max_uses    integer     NOT NULL DEFAULT 0 CHECK (max_uses >= 0),
    uses        integer     NOT NULL DEFAULT 0 CHECK (uses >= 0),
    starts_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    disabled_at timestamptz,
    created_by  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (max_uses = 0 OR uses <= max_uses)
);

-- Once per lord and once per phone. No foreign key to the lord: a redemption
-- outlives the account, so deleting and signing up again redeems nothing twice.
CREATE TABLE app.promo_redemptions (
    code        text        NOT NULL REFERENCES admin.promo_codes(code) ON DELETE CASCADE,
    player_id   uuid        NOT NULL,
    device_hash text        NOT NULL,
    redeemed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (code, player_id),
    UNIQUE (code, device_hash)
);

-- Wrong codes, for the hourly allowance. Kept a day.
CREATE TABLE app.promo_failures (
    id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id uuid        NOT NULL,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX promo_failures_player_idx ON app.promo_failures (player_id, at);

-- ============================================================================
-- Bringing a friend
-- ============================================================================
-- A lord's own code, made the first time they ask for it.
CREATE TABLE app.referral_codes (
    player_id  uuid        PRIMARY KEY REFERENCES app.players(id) ON DELETE CASCADE,
    code       text        NOT NULL UNIQUE CHECK (code ~ '^[A-Z2-9]{6}$'),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Who brought whom. One per friend; rewarded_at is set when the friend reached
-- the reward level and both letters were sent.
CREATE TABLE app.referrals (
    invitee_id  uuid        PRIMARY KEY REFERENCES app.players(id) ON DELETE CASCADE,
    inviter_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    device_hash text        NOT NULL,
    linked_at   timestamptz NOT NULL DEFAULT now(),
    rewarded_at timestamptz,
    CHECK (invitee_id <> inviter_id)
);
CREATE INDEX referrals_inviter_idx ON app.referrals (inviter_id, linked_at);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.referrals;
DROP TABLE IF EXISTS app.referral_codes;
DROP TABLE IF EXISTS app.promo_failures;
DROP TABLE IF EXISTS app.promo_redemptions;
DROP TABLE IF EXISTS admin.promo_codes;
DROP TABLE IF EXISTS app.player_devices;
-- +goose StatementEnd
