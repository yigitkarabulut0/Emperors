-- Herald's Tidings (migration 00049): the rewarded advert.

-- A watch is started. The row IS the ticket the SDK carries.
-- name: StartAdWatch :one
INSERT INTO app.ad_watches (player_id, unit, created_at, expires_at)
VALUES (sqlc.arg(player_id), sqlc.arg(unit), sqlc.arg(now), sqlc.arg(expires_at))
RETURNING *;

-- The ticket a callback names.
-- name: GetAdWatch :one
SELECT * FROM app.ad_watches WHERE id = sqlc.arg(id);

-- The same, locked, for the payment about to be made against it.
-- name: LockAdWatch :one
SELECT * FROM app.ad_watches WHERE id = sqlc.arg(id) FOR UPDATE;

-- This lord's watch in flight, if there is one: unpaid and not yet expired.
-- One at a time is what keeps a tap from minting tickets by the thousand.
-- name: LiveAdWatch :one
SELECT * FROM app.ad_watches
WHERE player_id = sqlc.arg(player_id) AND paid_at IS NULL AND expires_at > sqlc.arg(now)
ORDER BY created_at DESC
LIMIT 1;

-- What the lord has actually been PAID for since a moment: the day's allowance
-- is counted from watches that came back, never from taps. A watch started and
-- abandoned cost the lord nothing and must cost them nothing.
-- name: CountAdWatchesPaidSince :one
SELECT count(*)::bigint FROM app.ad_watches
WHERE player_id = sqlc.arg(player_id) AND paid_at >= sqlc.arg(since);

-- When this lord was last paid for one, for the cooldown between adverts.
-- name: LastAdWatchPaidAt :one
SELECT coalesce(max(paid_at), to_timestamp(0))::timestamptz AS last_paid
FROM app.ad_watches
WHERE player_id = sqlc.arg(player_id);

-- The payment. The WHERE is the guard: a second callback for the same watch
-- writes nothing, and the unique index on the transaction id catches a second
-- callback that named a different ticket.
-- name: PayAdWatch :one
UPDATE app.ad_watches
SET transaction_id = sqlc.arg(transaction_id), paid_at = sqlc.arg(now),
    diamonds = sqlc.arg(diamonds), key_id = sqlc.arg(key_id)
WHERE id = sqlc.arg(id) AND paid_at IS NULL
RETURNING *;

-- Tickets nobody came back for, and payments old enough to be history. The
-- sweep keeps the table the size of what it is actually for.
-- name: PurgeAdWatches :execrows
DELETE FROM app.ad_watches
WHERE (paid_at IS NULL AND expires_at < sqlc.arg(now))
   OR (paid_at IS NOT NULL AND paid_at < sqlc.arg(keep_before));

-- What the desk reads: what the herald paid in a window, and to how many lords.
-- name: DeskAds :one
SELECT count(*) FILTER (WHERE paid_at IS NOT NULL)::bigint AS paid,
       count(*)::bigint AS started,
       count(DISTINCT player_id) FILTER (WHERE paid_at IS NOT NULL)::bigint AS lords,
       coalesce(sum(diamonds), 0)::bigint AS diamonds
FROM app.ad_watches
WHERE created_at >= sqlc.arg(since);
