-- +goose Up
-- +goose StatementBegin

-- The storehouse. Estate income no longer lands in the purse on every request
-- (CreditTax, retired): it fills a storehouse at the hourly rate, up to 8 hours
-- of it (12 minutes more per Tithe Barn level, 12 hours at the top), and waits
-- there, out of a raider's reach, until the lord carries it to the purse or the
-- vault. Time past the capacity is lost: the reason to come back.
--
-- storehouse_milli is what it holds (milli-gold), storehouse_at when that was
-- last settled, and storehouse_cap_milli the capacity it has been filling
-- toward, cached beside tax_milli_per_hour so a change of either is settled at
-- the old pair first (RefreshStorehouse).
ALTER TABLE app.players
    ADD COLUMN storehouse_milli     bigint      NOT NULL DEFAULT 0 CHECK (storehouse_milli >= 0),
    ADD COLUMN storehouse_at        timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN storehouse_cap_milli bigint      NOT NULL DEFAULT 0 CHECK (storehouse_cap_milli >= 0);

-- What the estates earned under the old rule is paid now, into the purse, and
-- written to the gold ledger with whatever was still banked for it.
WITH owed AS (
    SELECT id,
           (tax_milli_accrued + tax_milli_per_hour
               * GREATEST(0, (EXTRACT(EPOCH FROM (now() - tax_updated_at)) * 1000)::bigint)
               / 3600000) / 1000 AS paid
    FROM app.players
)
UPDATE app.players p
SET gold              = p.gold + owed.paid,
    tax_unlogged      = p.tax_unlogged + owed.paid,
    tax_milli_accrued = 0,
    tax_updated_at    = now()
FROM owed
WHERE p.id = owed.id;

INSERT INTO app.gold_ledger (player_id, delta, balance_after, reason, ref_id)
SELECT id, tax_unlogged, gold, 'tax', 'storehouse opened'
FROM app.players
WHERE tax_unlogged > 0;

UPDATE app.players SET tax_unlogged = 0 WHERE tax_unlogged > 0;

-- Each storehouse opens empty now, at the capacity its rate and Tithe Barn
-- give (estates.tax: 28800 s, and 720 s a level). The game recomputes both from
-- the live balance on the lord's next request, settling at these first.
UPDATE app.players p
SET storehouse_at = now(),
    storehouse_cap_milli = p.tax_milli_per_hour
        * (28800 + 720 * LEAST(20, coalesce((SELECT u.level FROM app.player_upgrades u
                                            WHERE u.player_id = p.id AND u.upgrade_id = 'tithe_barn'), 0)))
        / 3600;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players
    DROP COLUMN IF EXISTS storehouse_cap_milli,
    DROP COLUMN IF EXISTS storehouse_at,
    DROP COLUMN IF EXISTS storehouse_milli;
-- +goose StatementEnd
