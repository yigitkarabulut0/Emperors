-- A/B tests. See migration 00037 and admin/experiments.go.

-- name: RecordExposure :exec
INSERT INTO app.experiment_exposures (experiment, player_id, arm, product_id, exposed_at)
VALUES (sqlc.arg(experiment), sqlc.arg(player_id), sqlc.arg(arm), sqlc.arg(product_id), sqlc.arg(at))
ON CONFLICT (experiment, player_id) DO NOTHING;

-- Each arm: how many lords were shown it, how many of them bought its product
-- afterwards, and what they paid. Production purchases only, as revenue is.
-- name: ExperimentResults :many
SELECT e.arm,
       count(*)::bigint AS exposed,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM app.iap_transactions t
           WHERE t.player_id = e.player_id AND t.product_id = e.product_id
             AND t.created_at >= e.exposed_at AND t.environment = 'Production'))::bigint AS converted,
       coalesce(sum((SELECT sum(t.usd_cents) FROM app.iap_transactions t
           WHERE t.player_id = e.player_id AND t.product_id = e.product_id
             AND t.created_at >= e.exposed_at AND t.environment = 'Production'
             AND t.state = 'granted')), 0)::bigint AS revenue_cents
FROM app.experiment_exposures e
WHERE e.experiment = sqlc.arg(experiment)
GROUP BY e.arm;
