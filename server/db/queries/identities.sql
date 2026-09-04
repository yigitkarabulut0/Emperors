-- name: CreateIdentity :one
INSERT INTO app.identities (player_id, kind, subject, secret_hash)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetIdentityBySubject :one
SELECT * FROM app.identities WHERE kind = $1 AND subject = $2;

-- name: MarkIdentityUsed :exec
UPDATE app.identities SET last_used_at = now() WHERE id = $1;
