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

// The Kingdom Shop: what donating actually buys the donor.
//
// Favour has been granted on every donation since kingdoms shipped — a hundred
// gold to the treasury, one favour to you — and displayed on the Realm card,
// and there has never been anywhere to spend it. So donating was pure cost to
// the individual and pure gain to the collective, which is the arrangement the
// design specifically warned would stop anyone donating at all.

// FavourGoodView is one line of the shop, with the reason it is unavailable
// rather than a silently dead button.
type FavourGoodView struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Cost  int64  `json:"cost"`
	// Useful is false when buying it would change nothing — already full energy,
	// a draught already running. A premium you cannot waste by accident is one
	// people spend.
	Useful bool   `json:"useful"`
	Note   string `json:"note,omitempty"`
}

// FavourShopView is the Kingdom Shop payload.
type FavourShopView struct {
	Favour int64            `json:"favour"`
	Goods  []FavourGoodView `json:"goods"`
}

// GetFavourShop lists what this player can spend their favour on.
func (d Deps) GetFavourShop(ctx context.Context, playerID uuid.UUID) (*FavourShopView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("favour shop: %w", err)
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	now := d.Now()

	out := &FavourShopView{Favour: p.KingdomFavour}
	out.Goods = make([]FavourGoodView, 0, len(d.Config.Kingdoms.FavourShop))
	for _, g := range d.Config.Kingdoms.FavourShop {
		v := FavourGoodView{ID: g.ID, Name: g.Name, Blurb: g.Blurb, Cost: g.Cost, Useful: true}
		switch g.ID {
		case "energy_potion":
			settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
			if economy.Whole(settled) >= maxEnergy {
				v.Useful, v.Note = false, "your energy is already full"
			}
		case "xp_boost":
			if p.XpBoostBp != 0 && p.XpBoostExpiresAt != nil && p.XpBoostExpiresAt.After(now) {
				v.Useful, v.Note = false, "a draught is already working"
			}
		}
		if p.KingdomFavour < g.Cost {
			v.Useful, v.Note = false, "not enough favour"
		}
		out.Goods = append(out.Goods, v)
	}
	return out, nil
}

// BuyFavourGood spends favour.
//
// One transaction, and the spend is the same statement as the check — zero rows
// back means they could not afford it, so a double tap cannot overdraw. The
// same shape every other purchase in the game uses.
func (d Deps) BuyFavourGood(ctx context.Context, playerID uuid.UUID, goodID string, wantSeq int64) (*FavourShopView, error) {
	var good *struct {
		Cost  int64
		BP    int64
		Hours int64
	}
	for _, g := range d.Config.Kingdoms.FavourShop {
		if g.ID == goodID {
			good = &struct {
				Cost  int64
				BP    int64
				Hours int64
			}{g.Cost, g.BP, g.Hours}
			break
		}
	}
	if good == nil {
		return nil, ErrNotFound
	}

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

		// Refuse before spending, so favour is never taken for nothing.
		switch goodID {
		case "energy_potion":
			settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
			if economy.Whole(settled) >= maxEnergy {
				return ErrNothingToBuy
			}
		case "xp_boost":
			if p.XpBoostBp != 0 && p.XpBoostExpiresAt != nil && p.XpBoostExpiresAt.After(now) {
				return ErrNothingToBuy
			}
		}

		after, err := q.SpendFavour(ctx, sqlcdb.SpendFavourParams{
			ID: playerID, Cost: good.Cost, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughFavour
			}
			return fmt.Errorf("spend favour: %w", err)
		}

		switch goodID {
		case "energy_potion":
			_, maxEnergy, _ := settleEnergy(d.Config, after, eff, now)
			filled := economy.Refill(maxEnergy, now)
			if err := q.RefillEnergy(ctx, sqlcdb.RefillEnergyParams{
				ID: playerID, EnergyMilli: filled.Milli, Now: filled.UpdatedAt,
			}); err != nil {
				return fmt.Errorf("potion: %w", err)
			}
		case "shop_refresh":
			windowID, _ := d.shopWindow()
			// Advancing the reroll index IS the refresh: the shop stores no
			// offers, it recomputes them from the counter.
			if _, err := q.BumpReroll(ctx, sqlcdb.BumpRerollParams{
				PlayerID: playerID, WindowID: windowID,
			}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("refresh: %w", err)
			}
		case "xp_boost":
			until := now.Add(time.Duration(good.Hours) * time.Hour)
			if err := q.GrantXPBoost(ctx, sqlcdb.GrantXPBoostParams{
				ID: playerID, Bp: int32(good.BP), ExpiresAt: &until,
			}); err != nil {
				return fmt.Errorf("draught: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetFavourShop(ctx, playerID)
}
