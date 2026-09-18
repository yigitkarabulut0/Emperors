package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

// Flasks: the free rewards' energy (a Tax Cart, a calendar square, a week's
// chest), a share of the lord's own pool in a bottle. A flask is not a refill:
// money never carries one (Validate), so the day's bought energy stays the
// three refills.

var (
	// ErrEnergyFull is a flask for a pool that is already full.
	ErrEnergyFull = errors.New("your energy is already full")
	// ErrNotUsable is a token that is not drunk (a pardon, a writ, a charter).
	ErrNotUsable = errors.New("that is not used here")
)

// FlaskResult is a flask drunk.
type FlaskResult struct {
	EnergyGained int64     `json:"energy_gained"`
	Snapshot     *Snapshot `json:"snapshot"`
}

// FlaskGood is a flask as the energy goods list it.
type FlaskGood struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Icon  string `json:"icon"`
	// The token it is, how many the lord holds, what it would restore now.
	TokenID string `json:"token_id"`
	Tokens  int64  `json:"tokens"`
	Amount  int64  `json:"amount"`
	Useful  bool   `json:"useful"`
}

// flaskAmount is what a flask of pct restores to a pool of maxEnergy: a share
// of it, at least one point.
func flaskAmount(pct, maxEnergy int64) int64 {
	return max(1, maxEnergy*pct/100)
}

// UseToken drinks one flask. It is the lord's own sequenced action: the client
// counts the energy it will have, as it does for a refill.
func (d Deps) UseToken(ctx context.Context, playerID uuid.UUID, token string, wantSeq int64) (*FlaskResult, error) {
	def := d.Config.Token(token)
	if def == nil || def.EnergyPct <= 0 {
		return nil, ErrNotUsable
	}
	var res FlaskResult
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		now := d.Now()
		settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
		before := economy.Whole(settled)
		if before >= maxEnergy {
			return ErrEnergyFull
		}
		if _, err := q.SpendToken(ctx, sqlcdb.SpendTokenParams{PlayerID: p.ID, Token: token, Qty: 1}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoToken
			}
			return fmt.Errorf("drink a flask: %w", err)
		}
		after := economy.Restore(settled, flaskAmount(def.EnergyPct, maxEnergy), maxEnergy, now)
		if _, err := q.DrinkFlask(ctx, sqlcdb.DrinkFlaskParams{
			ID: p.ID, EnergyMilli: after.Milli, EnergyUpdatedAt: after.UpdatedAt, ActionSeq: wantSeq,
		}); err != nil {
			return fmt.Errorf("drink a flask: %w", err)
		}
		res.EnergyGained = economy.Whole(after) - before
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// flaskGoods are the flasks the energy goods list, with what each would do now.
func (d Deps) flaskGoods(held map[string]int64, current, maxEnergy int64) []FlaskGood {
	out := []FlaskGood{}
	for _, t := range d.Config.Rewards.Tokens {
		if t.EnergyPct <= 0 {
			continue
		}
		amount := min(flaskAmount(t.EnergyPct, maxEnergy), max(0, maxEnergy-current))
		out = append(out, FlaskGood{
			ID: t.ID, Name: t.Name, Blurb: t.Blurb, Icon: t.Icon, TokenID: t.ID,
			Tokens: held[t.ID], Amount: amount, Useful: held[t.ID] > 0 && current < maxEnergy,
		})
	}
	return out
}
