-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- The diamond ledger
-- ============================================================================
-- Gold has had a ledger since migration 00003. Diamonds never did: every
-- level-up grant, daily square, refill, shield, reroll and rename moved
-- players.diamonds and left no trace, so "where did this player's diamonds come
-- from" had no answer and neither did "how many diamonds exist". That was merely
-- untidy while diamonds could only be earned. Once they can be BOUGHT, a refund
-- has to be able to find exactly what a purchase granted, and a player's balance
-- has to be reconcilable to the cent. Hence this, before any purchase exists.
--
-- NO foreign key to app.players, deliberately. Deleting an account cascades
-- through everything else it owns (Guideline 5.1.1(v)), but a record of what was
-- granted and spent -- and against which purchase -- must outlive the account:
-- Apple can refund a purchase after the buyer has deleted their lord. The rows
-- carry no personal data (no username, no device), only the player's id, and a
-- purge job removes them 90 days after the account is gone.
CREATE TABLE app.diamond_ledger (
    id            bigserial   PRIMARY KEY,
    player_id     uuid        NOT NULL,
    -- The change to players.diamonds. What the balance actually did.
    delta         bigint      NOT NULL,
    -- What was earned or spent before any refund debt was repaid out of it. For
    -- a spend this equals delta. For a credit to a player who owes diamonds it is
    -- larger than delta: the difference went to the debt, and a refund of THIS
    -- grant must be able to see the whole amount it gave.
    gross         bigint      NOT NULL,
    balance_after bigint      NOT NULL CHECK (balance_after >= 0),
    debt_after    bigint      NOT NULL DEFAULT 0 CHECK (debt_after >= 0),
    reason        text        NOT NULL,
    class         text        NOT NULL
                  CHECK (class IN ('earned','purchased','spent','admin','refund','opening')),
    -- What this row answers to: a battle id, a transaction id, a letter, a day.
    ref_id        text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT diamond_ledger_moves CHECK (delta <> 0 OR gross <> 0)
);

-- A player's own history, newest first: the admin panel's ledger tab.
CREATE INDEX diamond_ledger_player_idx ON app.diamond_ledger (player_id, created_at DESC);
-- The economy dashboard: diamonds created and destroyed, by reason, over a window.
CREATE INDEX diamond_ledger_reason_idx ON app.diamond_ledger (reason, created_at DESC);
-- A refund finds everything its purchase granted by transaction id.
CREATE INDEX diamond_ledger_ref_idx ON app.diamond_ledger (ref_id) WHERE ref_id IS NOT NULL;

-- ============================================================================
-- Refund debt
-- ============================================================================
-- A refunded purchase takes back the diamonds it granted. When they have already
-- been spent there is nothing to take, and "the player keeps what they refunded"
-- is not an acceptable answer -- so the shortfall becomes a debt, paid first out
-- of whatever the player earns next.
--
-- The CHECK is the invariant every credit relies on: a player who owes has
-- nothing in the purse. Credits therefore repay the debt before they reach the
-- balance, in the same statement, and a spend (which requires diamonds >= price)
-- can never succeed while anything is owed.
ALTER TABLE app.players
    ADD COLUMN diamond_debt bigint NOT NULL DEFAULT 0 CHECK (diamond_debt >= 0);
ALTER TABLE app.players
    ADD CONSTRAINT players_debt_means_empty CHECK (diamond_debt = 0 OR diamonds = 0);

-- Every existing balance enters the ledger as one opening row, so the sum of a
-- player's rows equals their balance from the first day and reconciles forever
-- after.
INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
SELECT id, diamonds, diamonds, diamonds, 'opening_balance', 'opening'
FROM app.players
WHERE diamonds > 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players DROP CONSTRAINT IF EXISTS players_debt_means_empty;
ALTER TABLE app.players DROP COLUMN IF EXISTS diamond_debt;
DROP TABLE IF EXISTS app.diamond_ledger;
-- +goose StatementEnd
