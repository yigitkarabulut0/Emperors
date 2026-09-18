-- Promo codes and bringing a friend. See migration 00036, service/promo.go and
-- service/referral.go.

-- name: TouchDevice :exec
INSERT INTO app.player_devices (player_id, device_hash)
VALUES (sqlc.arg(player_id), sqlc.arg(device_hash))
ON CONFLICT (player_id, device_hash) DO UPDATE SET last_seen = now();

-- Whether a lord has ever played on this phone.
-- name: PlayedOnDevice :one
SELECT EXISTS (SELECT 1 FROM app.player_devices
               WHERE player_id = sqlc.arg(player_id) AND device_hash = sqlc.arg(device_hash))::bool;

-- name: CreatePromoCode :one
INSERT INTO admin.promo_codes (code, note, reward, max_uses, starts_at, expires_at, created_by)
VALUES (sqlc.arg(code), sqlc.arg(note), sqlc.arg(reward), sqlc.arg(max_uses), sqlc.arg(starts_at),
        sqlc.narg(expires_at), sqlc.arg(created_by))
ON CONFLICT (code) DO NOTHING
RETURNING *;

-- name: ListPromoCodes :many
SELECT * FROM admin.promo_codes ORDER BY created_at DESC LIMIT sqlc.arg(lim);

-- name: DisablePromoCode :one
UPDATE admin.promo_codes SET disabled_at = sqlc.arg(at)
WHERE code = sqlc.arg(code) AND disabled_at IS NULL
RETURNING *;

-- name: GetPromoCode :one
SELECT * FROM admin.promo_codes WHERE code = sqlc.arg(code);

-- Counts one use, if the code is live and not used up. No row: it is not.
-- name: UsePromoCode :one
UPDATE admin.promo_codes SET uses = uses + 1
WHERE code = sqlc.arg(code) AND disabled_at IS NULL
  AND starts_at <= sqlc.arg(now)::timestamptz
  AND (expires_at IS NULL OR expires_at > sqlc.arg(now)::timestamptz)
  AND (max_uses = 0 OR uses < max_uses)
RETURNING *;

-- Whether this lord, or anyone on this phone, has redeemed the code.
-- name: PromoRedeemed :one
SELECT EXISTS (SELECT 1 FROM app.promo_redemptions a
               WHERE a.code = sqlc.arg(promo)::text AND a.player_id = sqlc.arg(player_id)::uuid)::bool AS by_lord,
       EXISTS (SELECT 1 FROM app.promo_redemptions b
               WHERE b.code = sqlc.arg(promo)::text AND b.device_hash = sqlc.arg(device_hash)::text)::bool AS by_device;

-- name: InsertPromoRedemption :exec
INSERT INTO app.promo_redemptions (code, player_id, device_hash)
VALUES (sqlc.arg(code), sqlc.arg(player_id), sqlc.arg(device_hash));

-- name: ListPromoRedemptions :many
SELECT r.player_id, coalesce(p.username, '')::text AS username, r.redeemed_at
FROM app.promo_redemptions r LEFT JOIN app.players p ON p.id = r.player_id
WHERE r.code = sqlc.arg(code)
ORDER BY r.redeemed_at DESC LIMIT sqlc.arg(lim);

-- name: RecordPromoFailure :exec
INSERT INTO app.promo_failures (player_id) VALUES (sqlc.arg(player_id));

-- name: CountPromoFailures :one
SELECT count(*)::int FROM app.promo_failures
WHERE player_id = sqlc.arg(player_id) AND at > sqlc.arg(since)::timestamptz;

-- name: PurgePromoFailures :execrows
DELETE FROM app.promo_failures WHERE at < sqlc.arg(before)::timestamptz;

-- name: GetReferralCode :one
SELECT * FROM app.referral_codes WHERE player_id = sqlc.arg(player_id);

-- A code is made once; no row back means the code was taken (try another) or
-- the lord already has one.
-- name: InsertReferralCode :one
INSERT INTO app.referral_codes (player_id, code) VALUES (sqlc.arg(player_id), sqlc.arg(code))
ON CONFLICT DO NOTHING
RETURNING *;

-- name: PlayerByReferralCode :one
SELECT p.* FROM app.referral_codes c JOIN app.players p ON p.id = c.player_id
WHERE c.code = sqlc.arg(code);

-- name: InsertReferral :one
INSERT INTO app.referrals (invitee_id, inviter_id, device_hash)
VALUES (sqlc.arg(invitee_id), sqlc.arg(inviter_id), sqlc.arg(device_hash))
ON CONFLICT (invitee_id) DO NOTHING
RETURNING *;

-- name: GetReferral :one
SELECT * FROM app.referrals WHERE invitee_id = sqlc.arg(invitee_id);

-- name: CountReferralLinks :one
SELECT count(*) FILTER (WHERE linked_at > sqlc.arg(since)::timestamptz)::int AS today,
       count(*) FILTER (WHERE rewarded_at IS NOT NULL)::int                 AS rewarded
FROM app.referrals WHERE inviter_id = sqlc.arg(inviter_id);

-- name: ListReferralsByInviter :many
SELECT r.invitee_id, p.display_name, p.level, r.linked_at, r.rewarded_at, p.avatar,
       p.cos_frame, p.cos_title, p.cos_color, p.cos_crest, p.vip_points
FROM app.referrals r JOIN app.players p ON p.id = r.invitee_id
WHERE r.inviter_id = sqlc.arg(inviter_id)
ORDER BY r.linked_at DESC LIMIT 50;

-- Marks a friend paid for, once. No row: already paid, or no friend link.
-- name: MarkReferralRewarded :one
UPDATE app.referrals SET rewarded_at = sqlc.arg(at)
WHERE invitee_id = sqlc.arg(invitee_id) AND rewarded_at IS NULL
RETURNING *;

-- Friends who have reached the reward level and are not yet paid for.
-- name: ListDueReferrals :many
SELECT r.invitee_id FROM app.referrals r JOIN app.players p ON p.id = r.invitee_id
WHERE r.rewarded_at IS NULL AND p.level >= sqlc.arg(level)::int
ORDER BY r.linked_at LIMIT 200;
