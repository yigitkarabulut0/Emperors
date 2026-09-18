package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Rerolling a soldier's tier.
//
// The Army screen's REROLL: pay, and the soldier's tier is drawn again from the
// same table a recruit of its type is drawn from. The result replaces the old
// tier -- it can go up and it can go down -- and everything else about the
// soldier stays: its slot, its type, its gear. The client can repeat it, one
// request at a time, until a tier the player chose comes up, and only while the
// game is open; nothing about it runs on the server between requests.
//
// It was HUNT once, which re-recruited in a server-side loop against a budget.
// This is one roll per request, so every roll is seen.

// RerollResult is one roll.
type RerollResult struct {
	Soldier    UnitView `json:"soldier"`
	TierBefore string   `json:"tier_before"`
	Paid       int64    `json:"paid"`
	GoldLeft   string   `json:"gold_left"`
	// What the next roll costs, which is what the client stops on when gold
	// runs short -- never a sum of its own.
	RerollCost int64     `json:"reroll_cost"`
	Snapshot   *Snapshot `json:"snapshot"`
}

// soldierRerollCost is what one roll costs: the recruit price less the dismiss refund.
//
// That is exactly what the manual loop costs -- dismiss for the refund, recruit
// again at full price -- so the button is never cheaper than doing it by hand,
// which would make the refund an arbitrage, and never dearer, which would make
// the button pointless. It keeps the gear on, which the manual loop does not.
func soldierRerollCost(cfg *gameconfig.Bundle, t *gameconfig.SoldierType, level int64) int64 {
	price := recruitCost(cfg, t, level) - dismissRefund(cfg, t, level)
	if price < 1 {
		return 1
	}
	return price
}

// RerollSoldier draws a soldier's tier again.
func (d Deps) RerollSoldier(ctx context.Context, playerID, soldierID uuid.UUID, wantSeq int64) (*RerollResult, error) {
	var res RerollResult
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
		s, err := q.LockSoldier(ctx, sqlcdb.LockSoldierParams{ID: soldierID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock soldier: %w", err)
		}
		// A soldier on the road cannot be rerolled into somebody else.
		if err := d.mustBeHome(ctx, q, soldierID); err != nil {
			return err
		}
		t := d.Config.SoldierType(s.TypeID)
		if t == nil {
			return ErrNotFound
		}

		price := soldierRerollCost(d.Config, t, int64(p.Level))
		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: price, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		// The recruit's own draw, luck and all, so the published odds are the
		// reroll's odds too. Seeded from the sequence, which only moves forward:
		// a retried request cannot draw again for a better tier. The soldier is
		// in the seed so two soldiers rerolled at the same seq could not share
		// a draw if that were ever possible.
		rng := game.SeedForString(d.ShopSecret, playerID.String()+":"+soldierID.String(),
			uint64(wantSeq), uint64(s.SlotIndex), 0x2E2011)
		tier := items.RollTier(d.Config, rng, t.Weights,
			items.EffectiveLuckCoef(t.LuckCoef, eff.LuckBP), int(p.Level))

		rolled, err := q.SetSoldierTier(ctx, sqlcdb.SetSoldierTierParams{
			ID: soldierID, PlayerID: playerID, Tier: tier,
			RolledConfigVersion: int32(d.Config.Version),
		})
		if err != nil {
			return fmt.Errorf("set tier: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -price, BalanceAfter: after.Gold,
			Reason: "reroll", RefID: strPtr(soldierID.String()),
		}); err != nil {
			return fmt.Errorf("ledger: %w", err)
		}

		// Built with its gear and the Family bonuses, exactly as the Army
		// screen builds it, so the stats the reroll panel shows after a roll
		// are the ones the soldier card shows after the panel closes.
		worn, err := q.ListItemsForSoldiers(ctx, playerID)
		if err != nil {
			return fmt.Errorf("soldier gear: %w", err)
		}
		gear := map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}
		for _, it := range worn {
			if it.EquippedSoldierID != nil && *it.EquippedSoldierID == soldierID {
				iv := d.itemView(it)
				gear[it.Slot] = &iv
			}
		}

		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.Rerolls: 1})
		res = RerollResult{
			Soldier:    d.soldierUnit(after, rolled, gear, eff),
			TierBefore: s.Tier,
			Paid:       price,
			GoldLeft:   itoa(after.Gold),
			RerollCost: soldierRerollCost(d.Config, t, int64(after.Level)),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	// The whole state, so the client adopts it rather than asking for it: an
	// auto-roll is a request a roll, and it was two.
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}
