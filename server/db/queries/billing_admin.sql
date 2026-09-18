-- The panel's billing desk. See internal/admin/billing.go.
--
-- Revenue is the App Store's Production transactions alone. Sandbox purchases
-- (App Review, TestFlight, our own tests) are counted beside them and never
-- added in. A purchase counts on the day it was bought, a refund on the day it
-- was refunded; usd_cents is the price tier in US cents.

-- name: BillingTotals :one
SELECT count(*) FILTER (WHERE environment = 'Production')::bigint                      AS purchases,
       coalesce(sum(usd_cents) FILTER (WHERE environment = 'Production'), 0)::bigint   AS gross_cents,
       count(DISTINCT player_id) FILTER (WHERE environment = 'Production')::bigint     AS payers,
       count(*) FILTER (WHERE environment = 'Sandbox')::bigint                         AS sandbox_purchases,
       coalesce(sum(usd_cents) FILTER (WHERE environment = 'Sandbox'), 0)::bigint      AS sandbox_cents
FROM app.iap_transactions
WHERE purchased_at >= sqlc.arg(since)::timestamptz;

-- Refunds Apple made, and purchases taken back by hand, apart: a revocation
-- returns no money, so it is not a refund.
-- name: BillingRefunds :one
SELECT count(*) FILTER (WHERE state = 'refunded')::bigint                    AS refunds,
       coalesce(sum(usd_cents) FILTER (WHERE state = 'refunded'), 0)::bigint AS refund_cents,
       count(*) FILTER (WHERE state = 'revoked')::bigint                     AS revoked
FROM app.iap_transactions
WHERE environment = 'Production' AND refunded_at >= sqlc.arg(since)::timestamptz;

-- One row per UTC day of the window, days without a sale included.
-- name: BillingDaily :many
SELECT d::date AS day,
       coalesce((SELECT sum(t.usd_cents) FROM app.iap_transactions t
                 WHERE t.environment = 'Production'
                   AND t.purchased_at >= d AND t.purchased_at < d + interval '1 day'), 0)::bigint AS gross_cents,
       coalesce((SELECT sum(t.usd_cents) FROM app.iap_transactions t
                 WHERE t.environment = 'Production' AND t.state = 'refunded'
                   AND t.refunded_at >= d AND t.refunded_at < d + interval '1 day'), 0)::bigint AS refund_cents,
       (SELECT count(*) FROM app.iap_transactions t
        WHERE t.environment = 'Production'
          AND t.purchased_at >= d AND t.purchased_at < d + interval '1 day')::bigint AS purchases
FROM generate_series(sqlc.arg(since)::timestamptz::date, sqlc.arg(until)::timestamptz::date, '1 day') AS d
ORDER BY d;

-- name: BillingByProduct :many
SELECT product_id,
       count(*)::bigint                                  AS purchases,
       coalesce(sum(usd_cents), 0)::bigint               AS gross_cents,
       count(*) FILTER (WHERE state = 'refunded')::bigint AS refunds,
       count(DISTINCT player_id)::bigint                 AS buyers
FROM app.iap_transactions
WHERE environment = 'Production' AND purchased_at >= sqlc.arg(since)::timestamptz
GROUP BY product_id
ORDER BY gross_cents DESC, product_id;

-- Lords who refund often: the same count the service's flag logs, in every
-- environment, so the panel and the log agree.
-- name: RefundFlagged :many
SELECT t.player_id,
       coalesce(p.username, '')::text                    AS username,
       (p.id IS NULL)::bool                              AS deleted,
       count(*)::bigint                                  AS refunds,
       coalesce(sum(t.usd_cents), 0)::bigint             AS refund_cents,
       max(t.refunded_at)::timestamptz                   AS last_refund
FROM app.iap_transactions t
LEFT JOIN app.players p ON p.id = t.player_id
WHERE t.state IN ('refunded', 'revoked') AND t.refunded_at > sqlc.arg(since)::timestamptz
GROUP BY t.player_id, p.id, p.username
HAVING count(*) >= sqlc.arg(min_refunds)::bigint
ORDER BY refunds DESC, last_refund DESC
LIMIT 50;

-- Transactions newest first, filtered; before_id pages back.
-- name: AdminListIAP :many
SELECT t.id, t.transaction_id, t.original_transaction_id, t.player_id,
       coalesce(p.username, '')::text AS username, (p.id IS NULL)::bool AS deleted,
       t.product_id, t.store_product_id, t.kind, t.environment, t.purchased_at, t.expires_at,
       t.usd_cents, t.price_milli, t.currency, t.storefront, t.granted, t.state,
       t.refunded_at, t.refund_note, t.created_at
FROM app.iap_transactions t
LEFT JOIN app.players p ON p.id = t.player_id
WHERE (sqlc.narg(player_id)::uuid IS NULL OR t.player_id = sqlc.narg(player_id)::uuid)
  AND (sqlc.arg(environment)::text = '' OR t.environment = sqlc.arg(environment)::text)
  AND (sqlc.arg(state)::text = '' OR t.state = sqlc.arg(state)::text)
  AND (sqlc.arg(search)::text = '' OR t.transaction_id = sqlc.arg(search)::text
       OR t.original_transaction_id = sqlc.arg(search)::text)
  AND (sqlc.arg(before_id)::bigint = 0 OR t.id < sqlc.arg(before_id)::bigint)
ORDER BY t.id DESC
LIMIT sqlc.arg(lim);

-- name: AdminListIAPNotifications :many
SELECT id, notification_uuid, type, subtype, environment, transaction_id, original_transaction_id,
       received_at, processed_at, outcome, attempts, last_error, next_attempt_at
FROM app.iap_notifications
WHERE (NOT sqlc.arg(open_only)::bool OR processed_at IS NULL)
ORDER BY id DESC
LIMIT sqlc.arg(lim);

-- name: ListPlayerSubscriptions :many
SELECT * FROM app.subscriptions WHERE player_id = sqlc.arg(player_id)
ORDER BY updated_at DESC;

-- What a lord has paid, Production and not refunded: the panel's lifetime spend.
-- name: PlayerSpend :one
SELECT coalesce(sum(usd_cents) FILTER (WHERE environment = 'Production' AND state = 'granted'), 0)::bigint AS spent_cents,
       count(*) FILTER (WHERE environment = 'Production')::bigint AS purchases,
       count(*) FILTER (WHERE environment = 'Sandbox')::bigint    AS sandbox_purchases
FROM app.iap_transactions WHERE player_id = sqlc.arg(player_id);

-- Who played in the window: distinct lords, and lord-days (the sum of each
-- day's active count), for conversion and revenue per daily active lord.
-- name: ActiveInWindow :one
SELECT count(DISTINCT player_id)::bigint AS lords, count(*)::bigint AS lord_days
FROM app.player_days WHERE day >= sqlc.arg(since)::date;

-- A lasting right given by hand from the panel, taken back the same way. Only
-- a right the panel gave: one a purchase gave is taken back with its purchase.
-- name: RevokeAdminEntitlement :execrows
UPDATE app.player_entitlements SET revoked_at = sqlc.arg(at)
WHERE player_id = sqlc.arg(player_id) AND entitlement = sqlc.arg(entitlement)
  AND revoked_at IS NULL AND transaction_id LIKE 'admin:%';
