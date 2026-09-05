package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

// StoreGood is one thing diamonds buy.
type StoreGood struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Blurb    string `json:"blurb"`
	Icon     string `json:"icon"`
	Diamonds int64  `json:"diamonds"`
	// Whether buying right now would do anything: a full pool cannot be refilled
	// and a standing shield should not be paid for twice.
	Useful bool   `json:"useful"`
	Note   string `json:"note,omitempty"`
}

// StoreView is the diamond half of the Shop screen.
type StoreView struct {
	Diamonds int64       `json:"diamonds"`
	Goods    []StoreGood `json:"goods"`
}

// GetStore lists what diamonds buy and whether each is worth buying now.
func (d Deps) GetStore(ctx context.Context, playerID uuid.UUID) (*StoreView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	now := d.Now()
	settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
	full := economy.Whole(settled) >= maxEnergy

	shielded := p.ShieldUntil != nil && p.ShieldUntil.After(now)
	cfg := d.Config.Progression.Store

	refill := StoreGood{
		ID: "energy_refill", Name: "Full Energy", Icon: "currency/bolt",
		Blurb:    fmt.Sprintf("Fill your pool back to %d right now.", maxEnergy),
		Diamonds: cfg.EnergyRefillDiamonds, Useful: !full,
	}
	if full {
		refill.Note = "your pool is already full"
	}

	shield := StoreGood{
		ID: "shield", Name: "Protection", Icon: "upgrades/bulwark",
		Blurb:    fmt.Sprintf("No one can raid you for %d hours.", cfg.ShieldHours),
		Diamonds: cfg.ShieldDiamonds, Useful: !shielded,
	}
	if shielded {
		shield.Note = "you are already protected"
	}

	return &StoreView{Diamonds: p.Diamonds, Goods: []StoreGood{refill, shield}}, nil
}

// BuyStoreGood spends diamonds.
//
// Refusing to sell something that would do nothing is deliberate: a player who
// pays twenty diamonds for a shield they already have has been taken, and a
// premium currency you cannot waste by accident is one people trust.
func (d Deps) BuyStoreGood(ctx context.Context, playerID uuid.UUID, good string, wantSeq int64) (*Snapshot, error) {
	cfg := d.Config.Progression.Store

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

		switch good {
		case "energy_refill":
			settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
			if economy.Whole(settled) >= maxEnergy {
				return ErrNothingToBuy
			}
			filled := economy.Refill(maxEnergy, now)
			if _, err := q.BuyEnergyRefill(ctx, sqlcdb.BuyEnergyRefillParams{
				ID: playerID, Diamonds: cfg.EnergyRefillDiamonds,
				EnergyMilli: filled.Milli, EnergyUpdatedAt: filled.UpdatedAt,
				ActionSeq: wantSeq,
			}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughDiamonds
				}
				return fmt.Errorf("refill: %w", err)
			}

		case "shield":
			if p.ShieldUntil != nil && p.ShieldUntil.After(now) {
				return ErrNothingToBuy
			}
			until := now.Add(time.Duration(cfg.ShieldHours) * time.Hour)
			if _, err := q.BuyShield(ctx, sqlcdb.BuyShieldParams{
				ID: playerID, Diamonds: cfg.ShieldDiamonds,
				ShieldUntil: &until, ActionSeq: wantSeq,
			}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughDiamonds
				}
				return fmt.Errorf("shield: %w", err)
			}

		default:
			return ErrNotFound
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetState(ctx, playerID)
}
