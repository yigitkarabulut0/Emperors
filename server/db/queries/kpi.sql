-- The daily KPI rollup (migration 00039, the kpi_rollup job).

-- One UTC day's figures, written again if they were written before. The day's
-- bounds are UTC midnights whatever the session's time zone.
-- name: RollupKPIDay :exec
INSERT INTO app.daily_kpi (day, dau, new_lords, payers, purchases, gross_cents, refund_cents,
                           diamonds_earned, diamonds_bought, diamonds_spent, computed_at)
SELECT d.day,
       (SELECT count(*) FROM app.player_days pd WHERE pd.day = d.day)::int,
       ((SELECT count(*) FROM app.players p
         WHERE NOT p.is_bot AND p.created_at >= d.lo AND p.created_at < d.hi)
        + (SELECT count(*) FROM app.deleted_accounts x
           WHERE x.joined_at >= d.lo AND x.joined_at < d.hi))::int,
       (SELECT count(DISTINCT t.player_id) FROM app.iap_transactions t
        WHERE t.environment = 'Production' AND t.purchased_at >= d.lo AND t.purchased_at < d.hi)::int,
       (SELECT count(*) FROM app.iap_transactions t
        WHERE t.environment = 'Production' AND t.purchased_at >= d.lo AND t.purchased_at < d.hi)::int,
       (SELECT coalesce(sum(t.usd_cents), 0) FROM app.iap_transactions t
        WHERE t.environment = 'Production' AND t.purchased_at >= d.lo AND t.purchased_at < d.hi)::bigint,
       (SELECT coalesce(sum(t.usd_cents), 0) FROM app.iap_transactions t
        WHERE t.environment = 'Production' AND t.state = 'refunded'
          AND t.refunded_at >= d.lo AND t.refunded_at < d.hi)::bigint,
       (SELECT coalesce(sum(l.gross), 0) FROM app.diamond_ledger l
        WHERE l.class = 'earned' AND l.created_at >= d.lo AND l.created_at < d.hi)::bigint,
       (SELECT coalesce(sum(l.gross), 0) FROM app.diamond_ledger l
        WHERE l.class = 'purchased' AND l.created_at >= d.lo AND l.created_at < d.hi)::bigint,
       (SELECT coalesce(-sum(l.gross), 0) FROM app.diamond_ledger l
        WHERE l.class = 'spent' AND l.created_at >= d.lo AND l.created_at < d.hi)::bigint,
       now()
FROM (SELECT sqlc.arg(day)::date AS day,
             (sqlc.arg(day)::date::timestamp AT TIME ZONE 'UTC') AS lo,
             ((sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'UTC') AS hi) d
ON CONFLICT (day) DO UPDATE
SET dau = EXCLUDED.dau, new_lords = EXCLUDED.new_lords, payers = EXCLUDED.payers,
    purchases = EXCLUDED.purchases, gross_cents = EXCLUDED.gross_cents, refund_cents = EXCLUDED.refund_cents,
    diamonds_earned = EXCLUDED.diamonds_earned, diamonds_bought = EXCLUDED.diamonds_bought,
    diamonds_spent = EXCLUDED.diamonds_spent, computed_at = EXCLUDED.computed_at;

-- The rolled-up days of a window, oldest first.
-- name: ListKPIDays :many
SELECT * FROM app.daily_kpi WHERE day >= sqlc.arg(since)::date ORDER BY day;
