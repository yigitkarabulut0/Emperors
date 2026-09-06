-- +goose Up
-- +goose StatementBegin

-- last_seen_at gets an index, and the presence registry becomes its only writer.
--
-- These two changes have to land together, and the reason is in migration 00002:
-- app.players is created WITH (fillfactor = 80) precisely so that gameplay
-- updates are HOT and "do not have to touch every index". A HOT update requires
-- that no INDEXED column changed -- and until this migration, eighteen mutating
-- queries set last_seen_at = now() inline. Indexing the column on its own would
-- therefore have made every collect, every purchase and every battle a non-HOT
-- update with a btree write attached, which is the exact cost the table was
-- shaped to avoid, and the same reason gold, xp and energy_milli are all
-- deliberately unindexed.
--
-- So the eighteen inline writes are gone. The registry observes every
-- authenticated request in memory and flushes the set through TouchPlayersSeen
-- once every thirty seconds. That is a write per player per half minute instead
-- of up to forty per second per tapping player, gameplay updates are HOT again,
-- and the column finally counts the players who were only browsing -- which it
-- never did, because a read-only endpoint mutates nothing and so touched
-- nothing.
--
-- Partial on NOT is_bot because every reader of this column excludes bots:
-- OnlineNow, ActiveDaily, PlayerCounts.active_1d/7d, and the last_seen sort in
-- BrowsePlayers. Bots never make requests, so their last_seen_at is frozen at
-- creation and indexing them would be dead weight that cmd/seedbots can inflate
-- at will.
CREATE INDEX players_last_seen_idx ON app.players (last_seen_at DESC) WHERE NOT is_bot;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX IF EXISTS app.players_last_seen_idx;
-- +goose StatementEnd
