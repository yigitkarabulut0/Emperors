-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- App Store purchases
-- ============================================================================
-- Every transaction the App Store signs for this app, once. The unique
-- (platform, transaction_id) is what makes a purchase idempotent: the client
-- sends it, a notification sends it again, a restore sends it a third time,
-- and it is granted exactly once.
--
-- No foreign key to the player: a purchase is a financial record and outlives
-- the account (migration 00033). A refund that arrives after a deletion finds
-- the row, finds app.deleted_accounts, and is settled as nothing to take back.
CREATE TABLE app.iap_transactions (
    id                      bigserial   PRIMARY KEY,
    platform                text        NOT NULL CHECK (platform = 'apple'),
    transaction_id          text        NOT NULL,
    original_transaction_id text        NOT NULL,
    player_id               uuid        NOT NULL,
    -- Ours (commerce.products[].id) and the App Store's.
    product_id              text        NOT NULL,
    store_product_id        text        NOT NULL,
    kind                    text        NOT NULL,
    environment             text        NOT NULL CHECK (environment IN ('Production', 'Sandbox')),
    purchased_at            timestamptz NOT NULL,
    expires_at              timestamptz,
    -- The price tier in US cents (what Royal Favour counts and revenue is
    -- reported in); what the player paid in their own currency beside it.
    usd_cents               bigint      NOT NULL,
    price_milli             bigint,
    currency                text,
    storefront              text,
    -- What the grant gave, as reward lines: support reads it, a refund undoes it.
    granted                 jsonb       NOT NULL DEFAULT '{}',
    state                   text        NOT NULL DEFAULT 'granted'
                            CHECK (state IN ('granted', 'refunded', 'revoked')),
    refunded_at             timestamptz,
    refund_note             text,
    -- The App Store's own signed words, kept as the proof.
    signed                  text        NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (platform, transaction_id)
);
CREATE INDEX iap_transactions_player_idx ON app.iap_transactions (player_id, created_at DESC);
CREATE INDEX iap_transactions_original_idx ON app.iap_transactions (original_transaction_id);
CREATE INDEX iap_transactions_created_idx ON app.iap_transactions (created_at);

-- App Store Server Notifications V2, stored before they are acted on: the
-- endpoint answers 200 once a notification is safely here, and a job retries
-- what failed for 72 hours. notification_uuid makes a redelivery a no-op.
CREATE TABLE app.iap_notifications (
    id                      bigserial   PRIMARY KEY,
    notification_uuid       text        NOT NULL UNIQUE,
    type                    text        NOT NULL,
    subtype                 text        NOT NULL DEFAULT '',
    environment             text        NOT NULL DEFAULT '',
    transaction_id          text,
    original_transaction_id text,
    signed_payload          text        NOT NULL,
    received_at             timestamptz NOT NULL DEFAULT now(),
    processed_at            timestamptz,
    outcome                 text,
    attempts                integer     NOT NULL DEFAULT 0,
    last_error              text,
    next_attempt_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX iap_notifications_pending_idx ON app.iap_notifications (next_attempt_at)
    WHERE processed_at IS NULL;

-- How many of each product a player has bought: the first purchase of a pack
-- pays double, and an offer is sold once. A refund does not give the first
-- purchase back, or buy-refund-buy would double every pack.
CREATE TABLE app.player_purchases (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    product_id text        NOT NULL,
    bought     integer     NOT NULL DEFAULT 0,
    first_at   timestamptz NOT NULL DEFAULT now(),
    last_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, product_id)
);

-- Lasting rights a non-consumable bought: the Steward, the Quartermaster.
CREATE TABLE app.player_entitlements (
    player_id      uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    entitlement    text        NOT NULL CHECK (entitlement IN ('steward', 'quartermaster')),
    transaction_id text        NOT NULL,
    granted_at     timestamptz NOT NULL DEFAULT now(),
    revoked_at     timestamptz,
    PRIMARY KEY (player_id, entitlement)
);

-- Crown Patronage, one row per subscription (its original transaction), kept
-- as the App Store reports it. players.patron_until mirrors the live one, so a
-- read of the player never needs this table.
CREATE TABLE app.subscriptions (
    original_transaction_id text        PRIMARY KEY,
    player_id               uuid        NOT NULL,
    product_id              text        NOT NULL,
    environment             text        NOT NULL,
    status                  text        NOT NULL
                            CHECK (status IN ('active', 'grace', 'billing_retry', 'expired', 'revoked')),
    expires_at              timestamptz NOT NULL,
    auto_renew              boolean     NOT NULL DEFAULT true,
    last_transaction_id     text        NOT NULL,
    updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX subscriptions_player_idx ON app.subscriptions (player_id);

-- Offers: a product shown once, when its moment comes (a level reached, the
-- day's refills gone, a raid suffered), for a limited time. A row is written
-- the first time the moment comes and never again, so an offer is shown once
-- per account; bought or lapsed, it stays as the record that it was.
CREATE TABLE app.player_offers (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    product_id text        NOT NULL,
    fired_at   timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    seen_at    timestamptz,
    PRIMARY KEY (player_id, product_id)
);

-- What purchases leave on the player, where every read already has it:
--   vip_points       US cents spent, less refunds: Royal Favour
--   patron_until     Crown Patronage runs until then
--   steward_owned    the Steward, bought for good
--   bag_bonus        bag slots bought for good (the Quartermaster)
--   stipend_until    the player's local day the Royal Stipend's last share is due
--   stipend_claimed  the local day its share was last claimed
--   stipend_ref      the transaction the running stipend answers to (its
--                    daily shares are ledgered against it, so a refund finds them)
--   vip_gift_on      the local day Royal Favour's gift was last claimed
ALTER TABLE app.players
    ADD COLUMN vip_points      bigint      NOT NULL DEFAULT 0 CHECK (vip_points >= 0),
    ADD COLUMN patron_until    timestamptz,
    ADD COLUMN steward_owned   boolean     NOT NULL DEFAULT false,
    ADD COLUMN bag_bonus       integer     NOT NULL DEFAULT 0 CHECK (bag_bonus >= 0),
    ADD COLUMN stipend_until   date,
    ADD COLUMN stipend_claimed date,
    ADD COLUMN stipend_ref     text,
    ADD COLUMN vip_gift_on     date;

-- The diamond ledger's refund rows answer to the transaction they undo.
-- (class 'purchased' and 'refund' already exist; nothing to add.)

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players
    DROP COLUMN IF EXISTS vip_gift_on,
    DROP COLUMN IF EXISTS stipend_ref,
    DROP COLUMN IF EXISTS stipend_claimed,
    DROP COLUMN IF EXISTS stipend_until,
    DROP COLUMN IF EXISTS bag_bonus,
    DROP COLUMN IF EXISTS steward_owned,
    DROP COLUMN IF EXISTS patron_until,
    DROP COLUMN IF EXISTS vip_points;
DROP TABLE IF EXISTS app.player_offers;
DROP TABLE IF EXISTS app.subscriptions;
DROP TABLE IF EXISTS app.player_entitlements;
DROP TABLE IF EXISTS app.player_purchases;
DROP TABLE IF EXISTS app.iap_notifications;
DROP TABLE IF EXISTS app.iap_transactions;
-- +goose StatementEnd
