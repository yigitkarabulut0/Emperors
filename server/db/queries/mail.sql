-- The Royal Mail. See migration 00031.

-- Sends one letter. The idempotency key makes a repeat of the same send a no-op:
-- zero rows back means the letter was already delivered.
-- name: InsertMail :one
INSERT INTO app.mail (player_id, kind, sender, title, body, attachments, idem_key, broadcast_id, expires_at)
VALUES (sqlc.arg(player_id), sqlc.arg(kind), sqlc.arg(sender), sqlc.arg(title), sqlc.arg(body),
        sqlc.arg(attachments), sqlc.narg(idem_key), sqlc.narg(broadcast_id), sqlc.arg(expires_at))
ON CONFLICT (player_id, idem_key) WHERE idem_key IS NOT NULL DO NOTHING
RETURNING *;

-- A player's inbox: every letter not deleted that can still be read -- claimable,
-- or already claimed and kept. An unclaimed letter past its expiry is gone.
-- name: ListMail :many
SELECT * FROM app.mail
WHERE player_id = sqlc.arg(player_id)
  AND deleted_at IS NULL
  AND (expires_at > sqlc.arg(now)::timestamptz OR claimed_at IS NOT NULL)
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(lim);

-- What the heartbeat flags: letters not yet read, or read with something still
-- to claim.
-- name: CountMailWaiting :one
SELECT count(*)::int FROM app.mail
WHERE player_id = sqlc.arg(player_id)
  AND deleted_at IS NULL
  AND expires_at > sqlc.arg(now)::timestamptz
  AND (read_at IS NULL OR (claimed_at IS NULL AND attachments <> '{}'::jsonb));

-- name: GetMail :one
SELECT * FROM app.mail WHERE id = sqlc.arg(id) AND player_id = sqlc.arg(player_id);

-- name: MarkMailRead :exec
UPDATE app.mail SET read_at = coalesce(read_at, now())
WHERE id = sqlc.arg(id) AND player_id = sqlc.arg(player_id);

-- Claims a letter. The whole rule is in the WHERE -- theirs, unclaimed, not
-- deleted, not expired -- so two taps or two devices get one claim.
-- name: ClaimMailRow :one
UPDATE app.mail SET claimed_at = now(), read_at = coalesce(read_at, now())
WHERE id = sqlc.arg(id) AND player_id = sqlc.arg(player_id)
  AND claimed_at IS NULL AND deleted_at IS NULL
  AND expires_at > sqlc.arg(now)::timestamptz
RETURNING *;

-- The letters CLAIM ALL opens: live, unclaimed, and carrying something.
-- name: ListClaimableMail :many
SELECT id FROM app.mail
WHERE player_id = sqlc.arg(player_id)
  AND claimed_at IS NULL AND deleted_at IS NULL
  AND expires_at > sqlc.arg(now)::timestamptz
  AND attachments <> '{}'::jsonb
ORDER BY created_at ASC, id ASC
LIMIT sqlc.arg(lim);

-- A letter can be thrown away once there is nothing left in it to claim.
-- name: DeleteMail :execrows
UPDATE app.mail SET deleted_at = sqlc.arg(now)::timestamptz
WHERE id = sqlc.arg(id) AND player_id = sqlc.arg(player_id) AND deleted_at IS NULL
  AND (claimed_at IS NOT NULL OR attachments = '{}'::jsonb OR expires_at <= sqlc.arg(now)::timestamptz);

-- The newest live 'all' letter, so a heartbeat can tell in one indexed read
-- whether this player has a copy still to make.
-- name: LatestAllBroadcast :one
SELECT coalesce(max(id), 0)::bigint FROM admin.mail_broadcasts
WHERE audience = 'all' AND revoked_at IS NULL AND expires_at > sqlc.arg(now)::timestamptz;

-- Gives this player their copy of every live 'all' letter newer than the last
-- they received. The key 'bc:<id>' makes it safe to run twice.
-- name: MaterializeBroadcasts :execrows
INSERT INTO app.mail (player_id, kind, sender, title, body, attachments, idem_key, broadcast_id, expires_at)
SELECT p.id, 'admin', b.sender, b.title, b.body, b.attachments, 'bc:' || b.id, b.id, b.expires_at
FROM admin.mail_broadcasts b
JOIN app.players p ON p.id = sqlc.arg(player_id)
WHERE b.audience = 'all' AND b.revoked_at IS NULL
  AND b.expires_at > sqlc.arg(now)::timestamptz
  AND b.id > p.mail_bc_seen
  AND (b.include_new OR p.created_at <= b.created_at)
ON CONFLICT (player_id, idem_key) WHERE idem_key IS NOT NULL DO NOTHING;

-- name: SetMailBroadcastSeen :exec
UPDATE app.players SET mail_bc_seen = GREATEST(mail_bc_seen, sqlc.arg(seen)::bigint)
WHERE id = sqlc.arg(id);

-- ----------------------------------------------------------------------------
-- Admin
-- ----------------------------------------------------------------------------

-- name: InsertBroadcast :one
INSERT INTO admin.mail_broadcasts (audience, segment, sender, title, body, attachments,
                                   include_new, expires_at, created_by, note)
VALUES (sqlc.arg(audience), sqlc.arg(segment), sqlc.arg(sender), sqlc.arg(title), sqlc.arg(body),
        sqlc.arg(attachments), sqlc.arg(include_new), sqlc.arg(expires_at), sqlc.arg(created_by),
        sqlc.arg(note))
RETURNING *;

-- Writes a segment letter for everyone who matches, at once. Bots never get
-- mail; they cannot read it.
-- name: SendSegmentMail :execrows
INSERT INTO app.mail (player_id, kind, sender, title, body, attachments, idem_key, broadcast_id, expires_at)
SELECT p.id, 'admin', b.sender, b.title, b.body, b.attachments, 'bc:' || b.id, b.id, b.expires_at
FROM admin.mail_broadcasts b, app.players p
WHERE b.id = sqlc.arg(broadcast_id)
  AND NOT p.is_bot AND p.state = 'active'
  AND p.level BETWEEN sqlc.arg(min_level)::int AND sqlc.arg(max_level)::int
  AND (sqlc.arg(active_days)::int = 0
       OR p.last_seen_at > now() - make_interval(days => sqlc.arg(active_days)::int))
ON CONFLICT (player_id, idem_key) WHERE idem_key IS NOT NULL DO NOTHING;

-- How many a segment send would reach, for the composer's preview.
-- name: CountSegment :one
SELECT count(*)::int FROM app.players p
WHERE NOT p.is_bot AND p.state = 'active'
  AND p.level BETWEEN sqlc.arg(min_level)::int AND sqlc.arg(max_level)::int
  AND (sqlc.arg(active_days)::int = 0
       OR p.last_seen_at > now() - make_interval(days => sqlc.arg(active_days)::int));

-- name: CountActivePlayers :one
SELECT count(*)::int FROM app.players WHERE NOT is_bot AND state = 'active';

-- name: SetBroadcastSent :exec
UPDATE admin.mail_broadcasts SET sent_count = sqlc.arg(sent_count) WHERE id = sqlc.arg(id);

-- delivered is every copy ever written; withdrawn, the unclaimed ones a revoke
-- took back (the revoke stamps them in its own transaction, so at its instant);
-- recipient names the lord a single-player letter went to.
-- name: ListBroadcasts :many
SELECT b.*,
       (SELECT count(*) FROM app.mail m WHERE m.broadcast_id = b.id)::int AS delivered,
       (SELECT count(*) FROM app.mail m WHERE m.broadcast_id = b.id AND m.claimed_at IS NOT NULL)::int AS claimed,
       (SELECT count(*) FROM app.mail m WHERE m.broadcast_id = b.id AND m.claimed_at IS NULL
          AND b.revoked_at IS NOT NULL AND m.deleted_at = b.revoked_at)::int AS withdrawn,
       coalesce((SELECT p.username FROM app.mail m JOIN app.players p ON p.id = m.player_id
                 WHERE m.broadcast_id = b.id AND b.audience = 'player' LIMIT 1), '')::text AS recipient
FROM admin.mail_broadcasts b
ORDER BY b.created_at DESC
LIMIT sqlc.arg(lim);

-- Revoking stops a letter reaching anyone else and takes back the copies nobody
-- has claimed yet. What was claimed stays claimed.
-- name: RevokeBroadcast :one
UPDATE admin.mail_broadcasts SET revoked_at = now(), revoked_by = sqlc.arg(revoked_by)
WHERE id = sqlc.arg(id) AND revoked_at IS NULL
RETURNING *;

-- name: DeleteUnclaimedBroadcastMail :execrows
UPDATE app.mail SET deleted_at = now()
WHERE broadcast_id = sqlc.arg(broadcast_id) AND claimed_at IS NULL AND deleted_at IS NULL;

-- Housekeeping: letters deleted, or expired unclaimed, longer ago than the keep
-- window. Claimed letters are kept until the same window passes their expiry.
-- name: PurgeMail :execrows
DELETE FROM app.mail
WHERE (deleted_at IS NOT NULL AND deleted_at < sqlc.arg(before)::timestamptz)
   OR expires_at < sqlc.arg(before)::timestamptz;
