-- name: CreateSession :one
INSERT INTO app.sessions (player_id, family_id, token_hash, expires_at, user_agent)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetSessionByTokenHash :one
SELECT * FROM app.sessions WHERE token_hash = $1;

-- name: MarkSessionUsed :exec
UPDATE app.sessions SET used_at = now() WHERE id = $1;

-- Revokes an entire rotation chain. Presenting an already-rotated refresh token
-- means the token was captured, so every descendant of that family is burned.
-- name: RevokeSessionFamily :exec
UPDATE app.sessions
SET revoked_at = now(), revoked_reason = $2
WHERE family_id = $1 AND revoked_at IS NULL;

-- name: RevokeSession :exec
UPDATE app.sessions SET revoked_at = now(), revoked_reason = $2 WHERE id = $1;
