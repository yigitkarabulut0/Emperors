-- +goose Up
-- +goose StatementBegin

-- Estate income cannot be driven by a server-wide event.
--
-- tax_milli_per_hour is a CACHED rate on the player row (see 00011): CreditTax
-- pays from the cache without recomputing effects, and the cache is only
-- rewritten when that player next reads their state. A boost that multiplied
-- the rate therefore persisted INTO the cache, and once the event ended nothing
-- refreshed it for a player who was offline -- so somebody who logged in during
-- a boosted hour and came back a week later was paid the boosted rate for the
-- whole week. Verified on a live row before removing it.
--
-- The list is duplicated between Go and the database on purpose, exactly the way
-- players.luck_bp duplicates the ceiling that items.ClampLuckBP enforces: Go
-- gates it in one place, and the database refuses to STORE a value that gate
-- would otherwise have to ignore.
-- Anything already stored for a bucket that is no longer boostable is retired
-- first. Revoked, not deleted: the table is append-only in spirit, and "why was
-- everyone earning more on the 6th" has to stay answerable. A revoked row is
-- also already inert -- ActiveBoosts filters on revoked_at IS NULL -- so this
-- stops the effect immediately, before the constraint is even added.
UPDATE admin.server_boosts
SET revoked_at = now(), revoked_by = 'migration 00015'
WHERE bucket NOT IN ('collect_income_bp', 'xp_bp', 'luck_bp')
  AND revoked_at IS NULL;

-- Retired rows still have to satisfy the constraint, so it is written to accept
-- historical buckets as long as they are no longer live.
ALTER TABLE admin.server_boosts
    ADD CONSTRAINT server_boosts_bucket CHECK (
        bucket IN ('collect_income_bp', 'xp_bp', 'luck_bp')
        OR revoked_at IS NOT NULL
    ) NOT VALID;

-- NOT VALID above, validated separately: the check applies to every new row
-- immediately, and this pass confirms nothing already stored breaks it without
-- taking an ACCESS EXCLUSIVE lock for the length of the scan.
ALTER TABLE admin.server_boosts VALIDATE CONSTRAINT server_boosts_bucket;

-- Any rate cached while a tax event was live is stale by definition. Zeroing it
-- costs nothing: the next state read recomputes it from the player's actual
-- holdings, and the accrual anchor is untouched, so no earned income is lost.
UPDATE app.players SET tax_milli_per_hour = 0 WHERE tax_milli_per_hour <> 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE admin.server_boosts DROP CONSTRAINT IF EXISTS server_boosts_bucket;
-- +goose StatementEnd
