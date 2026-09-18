-- What service.grantBundle writes, beyond the columns the player row already has.
-- See migration 00030.

-- name: UpsertToken :one
INSERT INTO app.player_tokens (player_id, token, qty, updated_at)
VALUES (sqlc.arg(player_id), sqlc.arg(token), sqlc.arg(qty)::bigint, now())
ON CONFLICT (player_id, token) DO UPDATE
SET qty = app.player_tokens.qty + EXCLUDED.qty, updated_at = now()
RETURNING *;

-- Uses tokens. Zero rows means the player does not hold that many, so the check
-- and the spend are one statement and a double tap cannot use one twice.
-- name: SpendToken :one
UPDATE app.player_tokens
SET qty = qty - sqlc.arg(qty)::bigint, updated_at = now()
WHERE player_id = sqlc.arg(player_id) AND token = sqlc.arg(token) AND qty >= sqlc.arg(qty)::bigint
RETURNING *;

-- name: ListTokens :many
SELECT token, qty FROM app.player_tokens WHERE player_id = $1 AND qty > 0 ORDER BY token;

-- name: InsertPlayerBoost :one
INSERT INTO app.player_boosts (player_id, bucket, amount_bp, starts_at, expires_at, source, source_ref)
VALUES (sqlc.arg(player_id), sqlc.arg(bucket), sqlc.arg(amount_bp), sqlc.arg(starts_at),
        sqlc.arg(expires_at), sqlc.arg(source), sqlc.narg(source_ref))
RETURNING *;

-- Keeps the player row's "a boost is live until" marker at the latest expiry, so
-- loadEffects reads the boost table only while one can still be live.
-- name: ExtendBoostUntil :exec
UPDATE app.players
SET boost_until = GREATEST(coalesce(boost_until, sqlc.arg(until)::timestamptz), sqlc.arg(until)::timestamptz)
WHERE id = sqlc.arg(id);

-- name: ListLiveBoosts :many
SELECT bucket, amount_bp, expires_at FROM app.player_boosts
WHERE player_id = sqlc.arg(player_id)
  AND starts_at <= sqlc.arg(now)::timestamptz
  AND expires_at > sqlc.arg(now)::timestamptz;

-- Grants a cosmetic. Zero rows back means the player already owns it (a
-- duplicate, which pays diamonds instead).
-- name: InsertCosmetic :one
INSERT INTO app.player_cosmetics (player_id, cosmetic_id, source, source_ref, expires_at)
VALUES (sqlc.arg(player_id), sqlc.arg(cosmetic_id), sqlc.arg(source), sqlc.narg(source_ref),
        sqlc.narg(expires_at))
ON CONFLICT (player_id, cosmetic_id) DO NOTHING
RETURNING *;

-- name: ListCosmetics :many
SELECT cosmetic_id, source, acquired_at, expires_at FROM app.player_cosmetics
WHERE player_id = $1 ORDER BY acquired_at;

-- name: CreditFavour :one
UPDATE app.players SET kingdom_favour = kingdom_favour + sqlc.arg(favour)::bigint
WHERE id = sqlc.arg(id)
RETURNING *;

-- Wears a cosmetic of one kind, or takes it off (an empty id). The EXISTS keeps
-- a lord from wearing what they do not own; the default crests are everyone's
-- and are passed in as owned by the service.
-- name: WearCosmetic :one
UPDATE app.players
SET cos_frame = CASE WHEN sqlc.arg(kind)::text = 'frame' THEN sqlc.narg(cosmetic_id) ELSE cos_frame END,
    cos_title = CASE WHEN sqlc.arg(kind)::text = 'title' THEN sqlc.narg(cosmetic_id) ELSE cos_title END,
    cos_color = CASE WHEN sqlc.arg(kind)::text = 'name_color' THEN sqlc.narg(cosmetic_id) ELSE cos_color END,
    cos_crest = CASE WHEN sqlc.arg(kind)::text = 'crest' THEN sqlc.narg(cosmetic_id) ELSE cos_crest END
WHERE id = sqlc.arg(id)
RETURNING *;

-- Takes off whatever a lord wears but no longer holds: a patron's frame whose
-- month ran out, a cosmetic a refund took back. Everyone's default crests have
-- no row and are always held. The worn columns are what every list of other
-- lords reads (raid cards, rankings, a kingdom's lords), so keeping them true
-- here is what lets those lists skip a check per row. player_id NULL sweeps
-- everyone (the cosmetics_lapse job); a player id tidies one lord at once.
-- name: UnwearLapsed :execrows
UPDATE app.players p SET
    cos_frame = CASE WHEN p.cos_frame = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
                    SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_frame
                      AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz))
                THEN p.cos_frame END,
    cos_title = CASE WHEN p.cos_title = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
                    SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_title
                      AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz))
                THEN p.cos_title END,
    cos_color = CASE WHEN p.cos_color = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
                    SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_color
                      AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz))
                THEN p.cos_color END,
    cos_crest = CASE WHEN p.cos_crest = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
                    SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_crest
                      AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz))
                THEN p.cos_crest END
WHERE (sqlc.narg(player_id)::uuid IS NULL OR p.id = sqlc.narg(player_id)::uuid)
  AND (p.cos_frame IS NOT NULL OR p.cos_title IS NOT NULL OR p.cos_color IS NOT NULL OR p.cos_crest IS NOT NULL)
  AND NOT (
      (p.cos_frame IS NULL OR p.cos_frame = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
          SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_frame
            AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz)))
      AND (p.cos_title IS NULL OR p.cos_title = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
          SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_title
            AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz)))
      AND (p.cos_color IS NULL OR p.cos_color = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
          SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_color
            AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz)))
      AND (p.cos_crest IS NULL OR p.cos_crest = ANY(sqlc.arg(defaults)::text[]) OR EXISTS (
          SELECT 1 FROM app.player_cosmetics c WHERE c.player_id = p.id AND c.cosmetic_id = p.cos_crest
            AND (c.expires_at IS NULL OR c.expires_at > sqlc.arg(now)::timestamptz))));
