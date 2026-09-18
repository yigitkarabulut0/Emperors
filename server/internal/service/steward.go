package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
)

// The Steward: a comfort bought for good (or kept by a patron) that collects,
// when the lord arrives, what is already theirs to claim -- the day's square,
// the carts at the gate, the Stipend's share, the Royal Courier's gift,
// Royal Favour's gift, the letters in the mailbag. It does not open carts while the lord is away: a yard it kept
// emptying would bring a paying lord more carts than one who comes back, and
// money never buys what the storehouse and the yard hold (their caps are
// everyone's).
//
// It produces nothing. Every line it collects is one the lord could have
// tapped for; it only saves the taps. It never keeps a streak alive on a day
// the lord did not come (it runs when they arrive), never collects energy or
// gold that is not already paid out, and never spends.
var ErrNotSteward = errors.New("the Steward does not serve this lord")

// StewardReport is what the Steward collected.
type StewardReport struct {
	Lines    []rewards.Line `json:"lines"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// RunSteward collects everything waiting for a lord the Steward serves. Each
// claim is its own transaction, as if tapped: one that cannot be made (a bag
// with no room for a letter's gear) leaves the rest collected.
func (d Deps) RunSteward(ctx context.Context, playerID uuid.UUID) (*StewardReport, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}
	if !d.stewardActive(p, d.Now()) {
		return nil, ErrNotSteward
	}
	rep := &StewardReport{Lines: []rewards.Line{}}

	// The day's square -- never a broken run's: mending one spends diamonds or
	// a pardon, and beginning anew gives the run up, and both are the lord's
	// to choose.
	if dv, err := d.GetDaily(ctx, playerID); err == nil && dv.Claimable && dv.Broken == nil {
		if res, err := d.ClaimDaily(ctx, playerID, ""); err == nil {
			rep.Lines = append(rep.Lines, res.Lines...)
		}
	}
	// The carts waiting at the gate (never the lord's writs: those are theirs to
	// spend). One transaction each, as if tapped; a prize with no room stops it.
	for i := 0; i < d.Config.Retention.Cart.Cap; i++ {
		var lines []rewards.Line
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			lp, err := tq.LockPlayer(ctx, playerID)
			if err != nil {
				return err
			}
			_, lines, err = d.openOneCart(ctx, tq, &lp, false, d.Now())
			if err == nil {
				d.recordDeeds(ctx, tx, lp, deeds.Deeds{deeds.CartsOpened: 1})
			}
			return err
		})
		if err != nil {
			break
		}
		rep.Lines = append(rep.Lines, lines...)
	}
	if res, err := d.ClaimStipend(ctx, playerID); err == nil {
		rep.Lines = append(rep.Lines, rewards.Line{Kind: "stipend", Amount: res.Diamonds,
			Text: fmt.Sprintf("The Royal Stipend: %d diamonds", res.Diamonds), Icon: "diamond"})
	}
	var gift []rewards.Line
	if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		tq := sqlcdb.New(tx)
		lp, err := tq.LockPlayer(ctx, playerID)
		if err != nil {
			return err
		}
		gift, err = d.claimDeal(ctx, tq, &lp, dealGift, true)
		return err
	}); err == nil {
		rep.Lines = append(rep.Lines, gift...)
	}
	// The Royal Courier's gift, while it is in the realm: gone with its hour.
	var courier Granted
	if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		tq := sqlcdb.New(tx)
		lp, err := tq.LockPlayer(ctx, playerID)
		if err != nil {
			return err
		}
		courier, err = d.claimHourlyGift(ctx, tq, &lp, d.Now())
		return err
	}); err == nil {
		rep.Lines = append(rep.Lines, courier.Lines...)
	}
	if res, err := d.ClaimVIPGift(ctx, playerID); err == nil {
		rep.Lines = append(rep.Lines, rewards.Line{Kind: "vip_gift", Amount: res.Diamonds,
			Text: fmt.Sprintf("Royal Favour's gift: %d diamonds", res.Diamonds), Icon: "diamond"})
	}
	if n, err := d.mailWaiting(ctx, q, p); err == nil && n > 0 {
		if res, err := d.ClaimAllMail(ctx, playerID); err == nil && len(res.Claimed) > 0 {
			rep.Lines = append(rep.Lines, res.Lines...)
		}
	}

	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	rep.Snapshot = snap
	return rep, nil
}
