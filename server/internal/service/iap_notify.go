package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// App Store Server Notifications V2: renewals, lapses, refunds, revocations.
//
// A notification is stored before anything is done with it, and the endpoint
// answers 200 as soon as it is stored: Apple retries anything that is not a
// 2xx, and a notification we hold is better retried by us (the
// iap_notifications job, for 72 hours) than resent by them.

// AppleNotify verifies and stores one notification, then tries to act on it.
func (d Deps) AppleNotify(ctx context.Context, signedPayload string) error {
	if d.IAP == nil {
		return ErrIAPUnavailable
	}
	n, err := d.IAP.Notification(signedPayload)
	if err != nil {
		if errors.Is(err, iap.ErrWrongApp) {
			return fmt.Errorf("%w: %v", ErrIAPWrongApp, err)
		}
		return fmt.Errorf("%w: %v", ErrIAPInvalid, err)
	}
	var txID, origID *string
	if n.Transaction != nil {
		txID, origID = &n.Transaction.TransactionID, &n.Transaction.OriginalTransactionID
	}
	id, err := sqlcdb.New(d.Pool).InsertIAPNotification(ctx, sqlcdb.InsertIAPNotificationParams{
		NotificationUuid: n.UUID, Type: n.Type, Subtype: n.Subtype, Environment: n.Data.Environment,
		TransactionID: txID, OriginalTransactionID: origID, SignedPayload: signedPayload,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // a redelivery of one we already hold
	}
	if err != nil {
		return fmt.Errorf("store notification: %w", err)
	}
	if _, err := d.processNotification(ctx, id); err != nil && d.Log != nil {
		d.Log.Warn("notification left for retry", "id", id, "type", n.Type, "err", err)
	}
	return nil
}

// processNotification acts on one stored notification, once, and says what it
// did. A failure is recorded on the row and retried by the job.
func (d Deps) processNotification(ctx context.Context, id int64) (string, error) {
	var outcome string
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		row, err := q.GetIAPNotification(ctx, id)
		if err != nil {
			return fmt.Errorf("notification %d: %w", id, err)
		}
		if row.ProcessedAt != nil {
			outcome = "already processed"
			return nil
		}
		// Re-verified from the stored bytes: nothing about the row is trusted
		// except the signature it carries.
		n, err := d.IAP.Notification(row.SignedPayload)
		if err != nil {
			return fmt.Errorf("re-verify: %w", err)
		}
		outcome, err = d.actOnNotification(ctx, tx, q, n)
		return err
	})
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	if err != nil {
		msg := err.Error()
		if ferr := q.FailIAPNotification(ctx, sqlcdb.FailIAPNotificationParams{ID: id, LastError: &msg, At: now}); ferr != nil {
			return "", fmt.Errorf("%v (and recording it: %v)", err, ferr)
		}
		return "", err
	}
	if outcome == "already processed" {
		return outcome, nil
	}
	return outcome, q.FinishIAPNotification(ctx, sqlcdb.FinishIAPNotificationParams{ID: id, At: &now, Outcome: &outcome})
}

// actOnNotification does what one notification asks, inside the caller's
// transaction, and says what it did.
func (d Deps) actOnNotification(ctx context.Context, tx pgx.Tx, q *sqlcdb.Queries, n *iap.Notification) (string, error) {
	t := n.Transaction
	switch n.Type {
	case iap.NotifySubscribed, iap.NotifyDidRenew, iap.NotifyOneTimeCharge:
		if t == nil {
			return "no transaction", nil
		}
		p, found, err := d.lockOwner(ctx, q, t)
		if err != nil || !found {
			return "unattributed: the app delivers it when it next sends it", err
		}
		del, err := d.deliverApple(ctx, tx, q, &p, t, n.Data.SignedTransactionInfo)
		if err != nil {
			return "", err
		}
		if del.Already {
			return "already delivered", nil
		}
		return "delivered " + del.Product, nil

	case iap.NotifyDidFailToRenew, iap.NotifyExpired, iap.NotifyGracePeriodExpired, iap.NotifyDidChangeRenewalState:
		if t == nil {
			return "no transaction", nil
		}
		return d.updateSubscription(ctx, q, n)

	case iap.NotifyRefund, iap.NotifyRevoke:
		if t == nil {
			return "no transaction", nil
		}
		state := "refunded"
		if n.Type == iap.NotifyRevoke {
			state = "revoked"
		}
		return d.undoApple(ctx, q, t, state, state+" by the App Store")

	case iap.NotifyRefundReversed:
		if t == nil {
			return "no transaction", nil
		}
		return d.reinstateApple(ctx, q, t)

	default:
		// TEST, CONSUMPTION_REQUEST, PRICE_INCREASE and the rest: kept, not acted on.
		return "noted " + n.Type, nil
	}
}

// lockOwner locks the lord a transaction belongs to: the one named by its
// appAccountToken, or whoever received its chain before.
func (d Deps) lockOwner(ctx context.Context, q *sqlcdb.Queries, t *iap.Transaction) (sqlcdb.AppPlayer, bool, error) {
	id := uuid.Nil
	if tok, err := uuid.Parse(t.AppAccountToken); err == nil {
		id = tok
	} else if owner, err := q.OwnerOfOriginal(ctx, t.OriginalTransactionID); err == nil {
		id = owner
	}
	if id == uuid.Nil {
		return sqlcdb.AppPlayer{}, false, nil
	}
	p, err := q.LockPlayer(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return sqlcdb.AppPlayer{}, false, nil
	}
	if err != nil {
		return sqlcdb.AppPlayer{}, false, fmt.Errorf("lock owner: %w", err)
	}
	return p, true, nil
}

// updateSubscription follows a subscription through billing trouble, grace
// and expiry. The player's patronage is always the latest of their live ones.
func (d Deps) updateSubscription(ctx context.Context, q *sqlcdb.Queries, n *iap.Notification) (string, error) {
	t := n.Transaction
	sub, err := q.GetSubscription(ctx, t.OriginalTransactionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "unknown subscription", nil
	}
	if err != nil {
		return "", fmt.Errorf("subscription: %w", err)
	}
	status := sub.Status
	var autoRenew pgtype.Bool
	switch n.Type {
	case iap.NotifyDidFailToRenew:
		status = "billing_retry"
		if n.Subtype == "GRACE_PERIOD" {
			status = "grace"
		}
	case iap.NotifyExpired, iap.NotifyGracePeriodExpired:
		status = "expired"
	case iap.NotifyDidChangeRenewalState:
		autoRenew = pgtype.Bool{Bool: n.Subtype == "AUTO_RENEW_ENABLED", Valid: true}
	}
	if _, err := q.SetSubscriptionStatus(ctx, sqlcdb.SetSubscriptionStatusParams{
		OriginalTransactionID: t.OriginalTransactionID, Status: status, AutoRenew: autoRenew,
	}); err != nil {
		return "", fmt.Errorf("set subscription: %w", err)
	}
	p, err := q.LockPlayer(ctx, sub.PlayerID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "subscription of a deleted account", nil
	}
	if err != nil {
		return "", fmt.Errorf("lock subscriber: %w", err)
	}
	if err := d.syncPatronUntil(ctx, q, &p); err != nil {
		return "", err
	}
	// A patronage that has ended takes its frame and colour with it now, not
	// at the end of a period that is no longer paid for.
	if p.PatronUntil == nil {
		now := d.Now()
		if err := q.EndHeldCosmetics(ctx, sqlcdb.EndHeldCosmeticsParams{PlayerID: p.ID, Source: "patronage", At: &now}); err != nil {
			return "", fmt.Errorf("end patron cosmetics: %w", err)
		}
		// And off their shoulders at once, not at the next sweep.
		if _, err := d.unwearLapsed(ctx, q, &p.ID, now); err != nil {
			return "", err
		}
	}
	// A patron in a grace period keeps the patronage until the grace ends.
	if status == "grace" && n.Renewal != nil && !n.Renewal.GracePeriodExpires().IsZero() {
		until := n.Renewal.GracePeriodExpires()
		if p.PatronUntil == nil || until.After(*p.PatronUntil) {
			after, err := q.SetPatronUntil(ctx, sqlcdb.SetPatronUntilParams{ID: p.ID, Until: &until})
			if err != nil {
				return "", fmt.Errorf("grace: %w", err)
			}
			p = after
		}
	}
	return "subscription " + status, nil
}

// undoApple takes back what a refunded or revoked transaction gave.
//
// Diamonds come back from the purse, and what has been spent becomes a debt
// paid first out of whatever the lord earns next. Tokens come back as far as
// they are still held; cosmetics and lasting rights are revoked; a stipend
// stops; a Largesse's unopened letters are withdrawn; Royal Favour falls.
func (d Deps) undoApple(ctx context.Context, q *sqlcdb.Queries, t *iap.Transaction, state, note string) (string, error) {
	now := d.Now()
	row, err := q.MarkIAPUndone(ctx, sqlcdb.MarkIAPUndoneParams{
		TransactionID: t.TransactionID, State: state, At: &now, Note: &note,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		prev, gerr := q.GetIAPTransaction(ctx, t.TransactionID)
		if gerr == nil {
			return "already " + prev.State, nil
		}
		if !errors.Is(gerr, pgx.ErrNoRows) {
			return "", fmt.Errorf("find transaction: %w", gerr)
		}
		// Refunded before it was ever delivered. Recording it now means the
		// app sending it later delivers nothing.
		owner := uuid.Nil
		if tok, perr := uuid.Parse(t.AppAccountToken); perr == nil {
			owner = tok
		}
		pr := d.Config.ProductByStoreID(t.ProductID)
		productID, kind, cents := t.ProductID, "", int64(0)
		if pr != nil {
			productID, kind, cents = pr.ID, pr.Kind, pr.USDCents
		}
		if _, err := q.InsertIAPTransaction(ctx, sqlcdb.InsertIAPTransactionParams{
			TransactionID: t.TransactionID, OriginalTransactionID: t.OriginalTransactionID, PlayerID: owner,
			ProductID: productID, StoreProductID: t.ProductID, Kind: kind, Environment: t.Environment,
			PurchasedAt: t.PurchaseDate(), UsdCents: cents, Signed: "(refund before delivery)",
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("record refunded transaction: %w", err)
		}
		if _, err := q.MarkIAPUndone(ctx, sqlcdb.MarkIAPUndoneParams{
			TransactionID: t.TransactionID, State: state, At: &now, Note: &note,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("mark refunded: %w", err)
		}
		return state + " before delivery", nil
	}
	if err != nil {
		return "", fmt.Errorf("mark undone: %w", err)
	}

	p, err := q.LockPlayer(ctx, row.PlayerID)
	if errors.Is(err, pgx.ErrNoRows) {
		if _, gerr := q.GetDeletedAccount(ctx, row.PlayerID); gerr == nil {
			return state + ": the account was deleted; nothing to take back", nil
		}
		return state + ": no such lord", nil
	}
	if err != nil {
		return "", fmt.Errorf("lock player: %w", err)
	}
	pr := d.Config.Product(row.ProductID)

	taken, debt := int64(0), int64(0)
	total, err := q.DiamondsGrantedFor(ctx, sqlcdb.DiamondsGrantedForParams{PlayerID: p.ID, Ref: row.TransactionID})
	if err != nil {
		return "", fmt.Errorf("diamonds granted: %w", err)
	}
	if total > 0 {
		after, err := q.RefundDiamonds(ctx, sqlcdb.RefundDiamondsParams{ID: p.ID, Amount: total})
		if err != nil {
			return "", fmt.Errorf("refund diamonds: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, -total, ledger.Refund, row.TransactionID); err != nil {
			return "", err
		}
		taken, debt = total, after.DiamondDebt-p.DiamondDebt
		p = after
	}

	if pr != nil {
		for token, n := range pr.Grant.Tokens {
			if err := q.TakeTokens(ctx, sqlcdb.TakeTokensParams{PlayerID: p.ID, Token: token, Qty: n}); err != nil {
				return "", fmt.Errorf("take tokens: %w", err)
			}
		}
		if pr.SeasonPass {
			if err := d.undoCharter(ctx, q, p, row.TransactionID); err != nil {
				return "", err
			}
		}
		if pr.Largesse != nil {
			if _, err := q.WithdrawUnclaimedMail(ctx, sqlcdb.WithdrawUnclaimedMailParams{
				At: &now, Prefix: "largesse:" + row.TransactionID + ":",
			}); err != nil {
				return "", fmt.Errorf("withdraw largesse: %w", err)
			}
		}
		if pr.Stipend != nil && p.StipendRef != nil && *p.StipendRef == row.TransactionID {
			yesterday := localDay(now, p.ResetOffsetMinutes).AddDate(0, 0, -1)
			after, err := q.SetStipend(ctx, sqlcdb.SetStipendParams{
				ID: p.ID, Until: pgtype.Date{Time: yesterday, Valid: true}, Ref: p.StipendRef,
			})
			if err != nil {
				return "", fmt.Errorf("stop stipend: %w", err)
			}
			p = after
		}
		if pr.Kind == gameconfig.ProductSubscription {
			if _, err := q.SetSubscriptionStatus(ctx, sqlcdb.SetSubscriptionStatusParams{
				OriginalTransactionID: row.OriginalTransactionID, Status: "revoked",
			}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return "", fmt.Errorf("revoke subscription: %w", err)
			}
			if err := d.syncPatronUntil(ctx, q, &p); err != nil {
				return "", err
			}
			if err := q.EndHeldCosmetics(ctx, sqlcdb.EndHeldCosmeticsParams{PlayerID: p.ID, Source: "patronage", At: &now}); err != nil {
				return "", fmt.Errorf("end patron cosmetics: %w", err)
			}
		}
	}
	if _, err := q.RevokeCosmeticsFrom(ctx, sqlcdb.RevokeCosmeticsFromParams{PlayerID: p.ID, Ref: row.TransactionID}); err != nil {
		return "", fmt.Errorf("revoke cosmetics: %w", err)
	}
	if n, err := q.RevokeEntitlementByTransaction(ctx, sqlcdb.RevokeEntitlementByTransactionParams{
		PlayerID: p.ID, TransactionID: row.TransactionID, At: &now,
	}); err != nil {
		return "", fmt.Errorf("revoke entitlement: %w", err)
	} else if n > 0 {
		after, err := q.SyncEntitlementFlags(ctx, sqlcdb.SyncEntitlementFlagsParams{
			ID: p.ID, QuartermasterBonus: int32(d.quartermasterBonus()),
		})
		if err != nil {
			return "", fmt.Errorf("entitlement flags: %w", err)
		}
		p = after
	}

	// Royal Favour falls with the money, and what a level gave goes with it.
	before := d.vipLevel(p)
	after, err := q.AddVIPPoints(ctx, sqlcdb.AddVIPPointsParams{ID: p.ID, Delta: -row.UsdCents})
	if err != nil {
		return "", fmt.Errorf("royal favour: %w", err)
	}
	p = after
	for lvl := before; lvl > d.vipLevel(p); lvl-- {
		if _, err := q.RevokeCosmeticsFrom(ctx, sqlcdb.RevokeCosmeticsFromParams{PlayerID: p.ID, Ref: vipRef(lvl)}); err != nil {
			return "", fmt.Errorf("royal favour cosmetics: %w", err)
		}
	}

	// Whatever the refund took back comes off their shoulders at once.
	if _, err := d.unwearLapsed(ctx, q, &p.ID, now); err != nil {
		return "", err
	}
	d.flagRefunds(ctx, q, p.ID, now)
	return fmt.Sprintf("%s: took back %d diamonds (%d as debt)", state, taken, debt), nil
}

// reinstateApple gives back what a refund Apple later reversed had taken.
func (d Deps) reinstateApple(ctx context.Context, q *sqlcdb.Queries, t *iap.Transaction) (string, error) {
	row, err := q.MarkIAPReinstated(ctx, t.TransactionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "nothing to reinstate", nil
	}
	if err != nil {
		return "", fmt.Errorf("reinstate: %w", err)
	}
	p, err := q.LockPlayer(ctx, row.PlayerID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "reinstated for a deleted account", nil
	}
	if err != nil {
		return "", fmt.Errorf("lock player: %w", err)
	}
	total, err := q.DiamondsGrantedFor(ctx, sqlcdb.DiamondsGrantedForParams{PlayerID: p.ID, Ref: row.TransactionID})
	if err != nil {
		return "", fmt.Errorf("diamonds granted: %w", err)
	}
	if total > 0 {
		after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: total})
		if err != nil {
			return "", fmt.Errorf("return diamonds: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, total, ledger.RefundReversed, row.TransactionID); err != nil {
			return "", err
		}
		p = after
	}
	if pr := d.Config.Product(row.ProductID); pr != nil {
		if pr.Entitlement != "" {
			if _, err := q.GrantEntitlement(ctx, sqlcdb.GrantEntitlementParams{
				PlayerID: p.ID, Entitlement: pr.Entitlement, TransactionID: row.TransactionID,
			}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return "", fmt.Errorf("entitlement: %w", err)
			}
			if p, err = q.SyncEntitlementFlags(ctx, sqlcdb.SyncEntitlementFlagsParams{
				ID: p.ID, QuartermasterBonus: int32(d.quartermasterBonus()),
			}); err != nil {
				return "", fmt.Errorf("entitlement flags: %w", err)
			}
		}
		b := pr.Grant
		b.Diamonds = 0
		if !b.Empty() {
			if _, err := d.grantBundle(ctx, q, &p, b, GrantSource{Diamonds: ledger.RefundReversed,
				Ref: row.TransactionID, ItemFrom: "purchase", Paid: true, DupeDiamonds: 0}); err != nil {
				return "", err
			}
		}
	}
	if _, err := d.addRoyalFavour(ctx, q, &p, row.UsdCents); err != nil {
		return "", err
	}
	return fmt.Sprintf("reinstated: %d diamonds returned", total), nil
}

// flagRefunds logs a lord who refunds often, for the panel's billing view.
func (d Deps) flagRefunds(ctx context.Context, q *sqlcdb.Queries, id uuid.UUID, now time.Time) {
	c := d.Config.Commerce
	n, err := q.CountRecentRefunds(ctx, sqlcdb.CountRecentRefundsParams{
		PlayerID: id, Since: now.AddDate(0, 0, -c.RefundFlagDays),
	})
	if err == nil && int(n) >= c.RefundFlagCount && d.Log != nil {
		d.Log.Warn("refund flag", "player", id, "refunds", n, "days", c.RefundFlagDays)
	}
}

// retryNotifications is the job that works through notifications whose first
// attempt failed.
func retryNotifications(ctx context.Context, d Deps, now time.Time) error {
	if d.IAP == nil {
		return nil
	}
	var ids []int64
	if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		rows, err := sqlcdb.New(tx).ClaimDueNotifications(ctx, sqlcdb.ClaimDueNotificationsParams{Now: now, Lim: 50})
		for _, r := range rows {
			ids = append(ids, r.ID)
		}
		return err
	}); err != nil {
		return fmt.Errorf("due notifications: %w", err)
	}
	var failed int
	for _, id := range ids {
		if _, err := d.processNotification(ctx, id); err != nil {
			failed++
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d notifications failed again", failed, len(ids))
	}
	return nil
}
