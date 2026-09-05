package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// CreditTax pays whatever the player's estates have earned since the last time
// they were paid, and moves the anchor.
//
// Called from middleware on every authenticated request. Whole gold goes into
// the purse; the sub-gold remainder stays in the accumulator, so polling four
// times a second loses nothing to rounding and the hourly rate is exactly the
// hourly rate however often it is settled.
//
// There is no cap. Estates earn while you are away for as long as you are away,
// which is what the Collect button used to stand in the way of.
func (d Deps) CreditTax(ctx context.Context, playerID uuid.UUID) error {
	q := sqlcdb.New(d.Pool)
	p, err := q.CreditTax(ctx, sqlcdb.CreditTaxParams{
		PlayerID: playerID, Now: d.Now(),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return fmt.Errorf("credit tax: %w", err)
	}

	// Estate income has to reach the gold ledger, or the economy dashboard --
	// whose entire job is to say whether the currency is inflating -- is not
	// measuring the currency. Removing the Collect button removed the only place
	// that recorded it, so the largest passive faucet in the game went invisible.
	//
	// Not one row per credit: income settles on every authenticated request,
	// which would be thousands of rows a day per player for a few gold each. The
	// credited amount accumulates on the row and is flushed once it is worth a
	// row. Totals stay exact; only their granularity is coarse.
	if p.TaxUnlogged < TaxLedgerFlush {
		return nil
	}
	if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
		PlayerID: playerID, Delta: p.TaxUnlogged, BalanceAfter: p.Gold,
		Reason: "tax", RefID: nil,
	}); err != nil {
		return fmt.Errorf("record tax: %w", err)
	}
	return q.ClearTaxUnlogged(ctx, playerID)
}

// TaxLedgerFlush is how much estate income banks up before it is written to the
// ledger as a single row. At the level-1 rate that is roughly one row every two
// hours per active player.
const TaxLedgerFlush = 50

// refreshTaxRate recomputes and stores the player's hourly estate income.
//
// The cached rate is what lets CreditTax be a single UPDATE with no reads. It
// has to be rewritten whenever anything feeding it changes -- a holding, a Family
// or kingdom upgrade, or a level -- and always AFTER the income earned so far has
// been credited, or the time already earned would be paid at the new rate.
func (d Deps) refreshTaxRate(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) error {
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return fmt.Errorf("tax rate: %w", err)
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return err
	}
	if p.TaxMilliPerHour == eff.TaxMilliPerHour {
		return nil
	}
	return q.SetTaxRate(ctx, sqlcdb.SetTaxRateParams{
		ID: playerID, TaxMilliPerHour: eff.TaxMilliPerHour,
	})
}
