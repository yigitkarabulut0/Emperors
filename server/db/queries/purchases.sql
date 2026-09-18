-- App Store purchases. See migration 00034.

-- Records a transaction once. No row back means it was already recorded: the
-- purchase was delivered before, and this call must not deliver it again.
-- name: InsertIAPTransaction :one
INSERT INTO app.iap_transactions (
    platform, transaction_id, original_transaction_id, player_id, product_id, store_product_id,
    kind, environment, purchased_at, expires_at, usd_cents, price_milli, currency, storefront, signed)
VALUES (
    'apple', sqlc.arg(transaction_id), sqlc.arg(original_transaction_id), sqlc.arg(player_id),
    sqlc.arg(product_id), sqlc.arg(store_product_id), sqlc.arg(kind), sqlc.arg(environment),
    sqlc.arg(purchased_at), sqlc.narg(expires_at), sqlc.arg(usd_cents), sqlc.narg(price_milli),
    sqlc.narg(currency), sqlc.narg(storefront), sqlc.arg(signed))
ON CONFLICT (platform, transaction_id) DO NOTHING
RETURNING *;

-- name: GetIAPTransaction :one
SELECT * FROM app.iap_transactions
WHERE platform = 'apple' AND transaction_id = sqlc.arg(transaction_id);

-- The account a purchase chain belongs to: whoever its first transaction was
-- delivered to. A non-consumable or a subscription restored on another account
-- is refused, so one Apple ID cannot furnish every lord on the phone.
-- name: OwnerOfOriginal :one
SELECT player_id FROM app.iap_transactions
WHERE platform = 'apple' AND original_transaction_id = sqlc.arg(original_transaction_id)
ORDER BY id LIMIT 1;

-- name: SetIAPGranted :exec
UPDATE app.iap_transactions SET granted = sqlc.arg(granted)
WHERE id = sqlc.arg(id);

-- Marks a delivered transaction refunded or revoked, once.
-- name: MarkIAPUndone :one
UPDATE app.iap_transactions
SET state = sqlc.arg(state), refunded_at = sqlc.arg(at), refund_note = sqlc.narg(note)
WHERE platform = 'apple' AND transaction_id = sqlc.arg(transaction_id) AND state = 'granted'
RETURNING *;

-- A refund Apple reversed: the transaction stands again.
-- name: MarkIAPReinstated :one
UPDATE app.iap_transactions
SET state = 'granted', refund_note = coalesce(refund_note, '') || ' reversed'
WHERE platform = 'apple' AND transaction_id = sqlc.arg(transaction_id) AND state = 'refunded'
RETURNING *;

-- Refunds in a window, for the panel's flag.
-- name: CountRecentRefunds :one
SELECT count(*)::int FROM app.iap_transactions
WHERE player_id = sqlc.arg(player_id) AND state IN ('refunded', 'revoked')
  AND refunded_at > sqlc.arg(since)::timestamptz;

-- Counts one more purchase of a product; the count after it (1 = the first).
-- name: BumpPurchase :one
INSERT INTO app.player_purchases (player_id, product_id, bought)
VALUES (sqlc.arg(player_id), sqlc.arg(product_id), 1)
ON CONFLICT (player_id, product_id)
DO UPDATE SET bought = app.player_purchases.bought + 1, last_at = now()
RETURNING bought;

-- name: ListPurchaseCounts :many
SELECT product_id, bought FROM app.player_purchases WHERE player_id = sqlc.arg(player_id);

-- Grants a lasting right. A row back means it was granted now; none means it
-- was already held.
-- name: GrantEntitlement :one
INSERT INTO app.player_entitlements (player_id, entitlement, transaction_id)
VALUES (sqlc.arg(player_id), sqlc.arg(entitlement), sqlc.arg(transaction_id))
ON CONFLICT (player_id, entitlement) DO UPDATE
SET revoked_at = NULL, transaction_id = EXCLUDED.transaction_id, granted_at = now()
WHERE app.player_entitlements.revoked_at IS NOT NULL
RETURNING *;

-- name: RevokeEntitlementByTransaction :execrows
UPDATE app.player_entitlements SET revoked_at = sqlc.arg(at)
WHERE player_id = sqlc.arg(player_id) AND transaction_id = sqlc.arg(transaction_id) AND revoked_at IS NULL;

-- name: ListEntitlements :many
SELECT entitlement, transaction_id, granted_at FROM app.player_entitlements
WHERE player_id = sqlc.arg(player_id) AND revoked_at IS NULL;

-- Mirrors the lasting rights onto the player, where every read has them.
-- name: SyncEntitlementFlags :one
UPDATE app.players p
SET steward_owned = EXISTS (SELECT 1 FROM app.player_entitlements e
                            WHERE e.player_id = p.id AND e.entitlement = 'steward' AND e.revoked_at IS NULL),
    bag_bonus = CASE WHEN EXISTS (SELECT 1 FROM app.player_entitlements e
                                  WHERE e.player_id = p.id AND e.entitlement = 'quartermaster'
                                    AND e.revoked_at IS NULL)
                     THEN sqlc.arg(quartermaster_bonus)::int ELSE 0 END
WHERE p.id = sqlc.arg(id)
RETURNING *;

-- name: UpsertSubscription :one
INSERT INTO app.subscriptions (original_transaction_id, player_id, product_id, environment, status,
                               expires_at, auto_renew, last_transaction_id, updated_at)
VALUES (sqlc.arg(original_transaction_id), sqlc.arg(player_id), sqlc.arg(product_id),
        sqlc.arg(environment), sqlc.arg(status), sqlc.arg(expires_at), sqlc.arg(auto_renew),
        sqlc.arg(last_transaction_id), now())
ON CONFLICT (original_transaction_id) DO UPDATE
SET status = EXCLUDED.status,
    -- A late notification never winds a subscription back.
    expires_at = GREATEST(app.subscriptions.expires_at, EXCLUDED.expires_at),
    auto_renew = EXCLUDED.auto_renew,
    last_transaction_id = EXCLUDED.last_transaction_id,
    updated_at = now()
RETURNING *;

-- name: SetSubscriptionStatus :one
UPDATE app.subscriptions
SET status = sqlc.arg(status), auto_renew = coalesce(sqlc.narg(auto_renew), auto_renew), updated_at = now()
WHERE original_transaction_id = sqlc.arg(original_transaction_id)
RETURNING *;

-- name: GetSubscription :one
SELECT * FROM app.subscriptions WHERE original_transaction_id = sqlc.arg(original_transaction_id);

-- The latest time any of a player's subscriptions keeps them a patron; the
-- epoch when none does.
-- name: PatronUntil :one
SELECT coalesce(max(expires_at), 'epoch'::timestamptz)::timestamptz FROM app.subscriptions
WHERE player_id = sqlc.arg(player_id) AND status IN ('active', 'grace', 'billing_retry');

-- name: SetPatronUntil :one
UPDATE app.players SET patron_until = sqlc.narg(until) WHERE id = sqlc.arg(id)
RETURNING *;

-- Royal Favour moves with money in and refunds out; never below zero.
-- name: AddVIPPoints :one
UPDATE app.players SET vip_points = GREATEST(0, vip_points + sqlc.arg(delta)::bigint)
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: SetStipend :one
UPDATE app.players SET stipend_until = sqlc.narg(until), stipend_ref = sqlc.narg(ref)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Claims today's stipend share, once, while the stipend runs. No row: nothing to claim.
-- name: ClaimStipendDay :one
UPDATE app.players SET stipend_claimed = sqlc.arg(today)::date
WHERE id = sqlc.arg(id) AND stipend_until >= sqlc.arg(today)::date
  AND (stipend_claimed IS NULL OR stipend_claimed < sqlc.arg(today)::date)
RETURNING *;

-- Claims Royal Favour's gift for today, once.
-- name: ClaimVIPGift :one
UPDATE app.players SET vip_gift_on = sqlc.arg(today)::date
WHERE id = sqlc.arg(id) AND vip_points > 0
  AND (vip_gift_on IS NULL OR vip_gift_on < sqlc.arg(today)::date)
RETURNING *;

-- Takes diamonds back for a refund. What is not there becomes a debt, paid
-- first out of the next diamonds earned. Both right-hand sides read the row as
-- it was: holding 30 and refunding 100 leaves 0 and a debt of 70.
-- name: RefundDiamonds :one
UPDATE app.players
SET diamonds     = GREATEST(0, diamonds - sqlc.arg(amount)::bigint),
    diamond_debt = diamond_debt + GREATEST(0, sqlc.arg(amount)::bigint - diamonds)
WHERE id = sqlc.arg(id)
RETURNING *;

-- Everything a transaction credited in diamonds, whatever went to a debt.
-- name: DiamondsGrantedFor :one
SELECT coalesce(sum(gross), 0)::bigint FROM app.diamond_ledger
WHERE player_id = sqlc.arg(player_id) AND ref_id = sqlc.arg(ref)::text
  AND class = 'purchased' AND gross > 0;

-- Takes back tokens a refunded purchase gave, as far as they are still held.
-- name: TakeTokens :exec
UPDATE app.player_tokens SET qty = GREATEST(0, qty - sqlc.arg(qty)::bigint)
WHERE player_id = sqlc.arg(player_id) AND token = sqlc.arg(token);

-- name: RevokeCosmeticsFrom :execrows
DELETE FROM app.player_cosmetics
WHERE player_id = sqlc.arg(player_id) AND source_ref = sqlc.arg(ref)::text;

-- Grants a cosmetic held for a time (a patron's frame), or extends it.
-- name: HoldCosmeticUntil :exec
INSERT INTO app.player_cosmetics (player_id, cosmetic_id, source, source_ref, expires_at)
VALUES (sqlc.arg(player_id), sqlc.arg(cosmetic_id), sqlc.arg(source), sqlc.narg(source_ref), sqlc.arg(until))
ON CONFLICT (player_id, cosmetic_id) DO UPDATE
SET expires_at = CASE WHEN app.player_cosmetics.expires_at IS NULL THEN NULL
                      ELSE GREATEST(app.player_cosmetics.expires_at, EXCLUDED.expires_at) END;

-- name: EndHeldCosmetics :exec
UPDATE app.player_cosmetics SET expires_at = sqlc.arg(at)
WHERE player_id = sqlc.arg(player_id) AND source = sqlc.arg(source)
  AND expires_at IS NOT NULL AND expires_at > sqlc.arg(at);

-- Takes back the letters a refunded gift sent that nobody opened.
-- name: WithdrawUnclaimedMail :execrows
UPDATE app.mail SET deleted_at = sqlc.arg(at)
WHERE idem_key LIKE sqlc.arg(prefix)::text || '%' AND claimed_at IS NULL AND deleted_at IS NULL;

-- Largesse letters a member received in a window, for the daily cap.
-- name: CountLargesseReceived :one
SELECT count(*)::int FROM app.mail
WHERE player_id = sqlc.arg(player_id) AND kind = 'largesse'
  AND created_at > sqlc.arg(since)::timestamptz;

-- The members a Largesse reaches: everyone else in the kingdom who has been in
-- it long enough.
-- name: LargesseRecipients :many
SELECT id FROM app.players
WHERE kingdom_id = sqlc.arg(kingdom_id) AND id <> sqlc.arg(buyer)
  AND kingdom_joined_at <= sqlc.arg(joined_before)::timestamptz AND NOT is_bot;

-- Notifications, stored before they are acted on.
-- name: InsertIAPNotification :one
INSERT INTO app.iap_notifications (notification_uuid, type, subtype, environment, transaction_id,
                                   original_transaction_id, signed_payload)
VALUES (sqlc.arg(notification_uuid), sqlc.arg(type), sqlc.arg(subtype), sqlc.arg(environment),
        sqlc.narg(transaction_id), sqlc.narg(original_transaction_id), sqlc.arg(signed_payload))
ON CONFLICT (notification_uuid) DO NOTHING
RETURNING id;

-- The notifications due another try, locked for this worker.
-- name: ClaimDueNotifications :many
SELECT * FROM app.iap_notifications
WHERE processed_at IS NULL AND next_attempt_at <= sqlc.arg(now)::timestamptz
  AND received_at > sqlc.arg(now)::timestamptz - interval '72 hours'
ORDER BY id
LIMIT sqlc.arg(lim)
FOR UPDATE SKIP LOCKED;

-- name: GetIAPNotification :one
SELECT * FROM app.iap_notifications WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: FinishIAPNotification :exec
UPDATE app.iap_notifications
SET processed_at = sqlc.arg(at), outcome = sqlc.arg(outcome), attempts = attempts + 1, last_error = NULL
WHERE id = sqlc.arg(id);

-- A failed attempt waits longer each time: 1, 2, 4 ... minutes, at most an hour.
-- name: FailIAPNotification :exec
UPDATE app.iap_notifications
SET attempts = attempts + 1, last_error = sqlc.arg(last_error),
    next_attempt_at = sqlc.arg(at)::timestamptz
                      + make_interval(mins => LEAST(60, power(2, attempts)::int))
WHERE id = sqlc.arg(id);

-- Spends diamonds on something the Splendour shop sells. The WHERE is the
-- affordability check; a player who owes a debt holds none to spend.
-- name: SpendDiamonds :one
UPDATE app.players SET diamonds = diamonds - sqlc.arg(amount)::bigint
WHERE id = sqlc.arg(id) AND diamonds >= sqlc.arg(amount)::bigint
RETURNING *;

-- Fires an offer, once per account. A row back means it fired now.
-- name: FireOffer :one
INSERT INTO app.player_offers (player_id, product_id, fired_at, expires_at)
VALUES (sqlc.arg(player_id), sqlc.arg(product_id), sqlc.arg(fired_at), sqlc.arg(expires_at))
ON CONFLICT (player_id, product_id) DO NOTHING
RETURNING *;

-- name: ListOffers :many
SELECT * FROM app.player_offers WHERE player_id = sqlc.arg(player_id);

-- name: MarkOffersSeen :exec
UPDATE app.player_offers SET seen_at = sqlc.arg(at)
WHERE player_id = sqlc.arg(player_id) AND seen_at IS NULL AND expires_at > sqlc.arg(at);
