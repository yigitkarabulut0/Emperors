package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
)

// The billing desk's two hands on a purchase. Both run the code Apple's own
// notifications run, so a refund applied from the panel takes back exactly
// what Apple's would have, and the ledger reads the same either way.

// ErrBadTakeBack is a take-back that names no state a purchase can end in.
var ErrBadTakeBack = errors.New(`a purchase is taken back as "refunded" or "revoked"`)

// RetryNotification acts on one stored notification now -- whatever its age,
// whatever its next scheduled try -- and says what it did. One already acted
// on says so and is left alone.
func (d Deps) RetryNotification(ctx context.Context, id int64) (string, error) {
	if d.IAP == nil {
		return "", ErrIAPUnavailable
	}
	out, err := d.processNotification(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return out, err
}

// TakeBack undoes a delivered purchase from the panel. "refunded" is for a
// refund Apple made whose notice never arrived (the retries ran out); "revoked"
// is support taking back what should not have been delivered. note is why, and
// is kept on the transaction.
func (d Deps) TakeBack(ctx context.Context, transactionID, state, note string) (string, error) {
	if state != "refunded" && state != "revoked" {
		return "", ErrBadTakeBack
	}
	var out string
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		row, err := q.GetIAPTransaction(ctx, transactionID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("find transaction: %w", err)
		}
		if row.State != "granted" {
			out = "already " + row.State
			return nil
		}
		// undoApple reads what the stored row already holds; the rest of a
		// signed transaction only matters for one it has never seen.
		t := &iap.Transaction{
			TransactionID: row.TransactionID, OriginalTransactionID: row.OriginalTransactionID,
			ProductID: row.StoreProductID, AppAccountToken: row.PlayerID.String(),
			Environment: row.Environment, PurchaseDateMS: row.PurchasedAt.UnixMilli(),
		}
		out, err = d.undoApple(ctx, q, t, state, note)
		return err
	})
	return out, err
}
