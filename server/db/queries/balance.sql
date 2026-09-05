-- The newest activation is the live configuration. Joining rather than storing
-- an "active" flag means a rollback is another append, and the history of what
-- was live when survives — the only way to explain an old battle after a
-- rebalance.
-- name: ActiveBalance :one
SELECT v.id, v.doc, v.sha256, v.note, v.created_at, a.activated_at, a.activated_by
FROM admin.balance_activations a
JOIN admin.balance_versions v ON v.id = a.version_id
ORDER BY a.activated_at DESC, a.id DESC
LIMIT 1;

-- name: CreateBalanceVersion :one
INSERT INTO admin.balance_versions (doc, sha256, note, created_by)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: ActivateBalanceVersion :one
INSERT INTO admin.balance_activations (version_id, activated_by, reason)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetBalanceVersion :one
SELECT * FROM admin.balance_versions WHERE id = $1;

-- name: ListBalanceVersions :many
SELECT v.*,
       EXISTS (SELECT 1 FROM admin.balance_activations a WHERE a.version_id = v.id)::boolean
         AS ever_activated
FROM admin.balance_versions v
ORDER BY v.id DESC
LIMIT $1;

-- name: CountBalanceVersions :one
SELECT count(*) FROM admin.balance_versions;
