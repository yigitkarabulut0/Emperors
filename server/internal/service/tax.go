package service

import (
	"context"
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
	if _, err := q.CreditTax(ctx, sqlcdb.CreditTaxParams{
		ID: playerID, Now: d.Now(),
	}); err != nil {
		if err == pgx.ErrNoRows {
			return nil
		}
		return fmt.Errorf("credit tax: %w", err)
	}
	return nil
}

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
