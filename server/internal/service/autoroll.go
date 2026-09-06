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
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

// AutoRollMax is how many rolls one request may run.
//
// The same reasoning as CollectBatch's cap: the run holds the player's row lock
// for its whole length, so an unbounded budget would let a client park that lock
// as long as it liked. Thirty is enough to make a Mystic hunt feel like one
// action at the Gladiator's 1-in-12 odds, and short enough that the transaction
// stays brief.
const AutoRollMax = 30

// AutoRollResult is what the chase produced.
//
// Stopping short is a normal outcome, not an error: running out of gold, or out
// of rolls, is the answer to "how far did my budget get me".
type AutoRollResult struct {
	Rolls          int    `json:"rolls"`
	GoldSpent      int64  `json:"gold_spent"`
	FinalTier      string `json:"final_tier"`
	HitTarget      bool   `json:"hit_target"`
	BestTier       string `json:"best_tier"`
	AppliedThrough int64  `json:"applied_through"`
	StoppedBecause string `json:"stopped_because"`

	Army *ArmyView `json:"army"`
}

// AutoRoll recruits into one slot over and over until it hits the tier the
// player asked for, their gold budget runs out, or the roll cap is reached.
//
// Why this exists at all: the manual version is recruit → look → dismiss →
// recruit, and at a Gladiator's 1-in-67 odds on a Special that is sixty-seven
// round trips and sixty-seven confirmation dialogs for one decision. The
// decision is "spend up to N gold chasing a Mystic", and this endpoint is that
// decision.
//
// Priced per roll at the recruit cost MINUS the dismiss refund, because that is
// exactly what the patient manual loop costs. Charging full price would make
// the convenience a penalty and nobody would use it.
func (d Deps) AutoRoll(ctx context.Context, playerID uuid.UUID, slotIndex int, typeID, targetTier string, maxGold int64, wantSeq int64) (*AutoRollResult, error) {
	t := d.Config.SoldierType(typeID)
	if t == nil {
		return nil, ErrNotFound
	}
	targetRank := d.Config.TierRank(targetTier)
	if targetRank <= 0 {
		return nil, ErrNotFound
	}
	if maxGold <= 0 {
		return nil, ErrNothingToSpend
	}

	res := &AutoRollResult{}
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
		if slotIndex < 1 || slotIndex > int(p.SoldierSlots) {
			return ErrNoSlot
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}

		// What one roll costs: the recruit price less what dismissing the
		// previous occupant gives back.
		full := recruitCost(d.Config, t, int64(p.Level))
		perRoll := full - full*d.Config.Items.Price.SellRatioBP/10000
		if perRoll < 1 {
			perRoll = 1
		}
		if maxGold < perRoll {
			return ErrNotEnoughGold
		}

		// The gear of whoever is standing there goes back to the bag once, not
		// once per roll: only the final soldier survives the run.
		existing, err := q.ListSoldiers(ctx, playerID)
		if err != nil {
			return fmt.Errorf("soldiers: %w", err)
		}
		for i := range existing {
			if int(existing[i].SlotIndex) == slotIndex {
				if err := q.ReleaseSoldierItems(ctx, sqlcdb.ReleaseSoldierItemsParams{
					PlayerID: playerID, EquippedSoldierID: &existing[i].ID,
				}); err != nil {
					return fmt.Errorf("release gear: %w", err)
				}
				break
			}
		}

		budget := maxGold
		if budget > p.Gold {
			budget = p.Gold
		}
		luck := items.EffectiveLuckCoef(t.LuckCoef, eff.LuckBP)

		tier := ""
		bestRank := 0
		for res.Rolls < AutoRollMax {
			if budget-res.GoldSpent < perRoll {
				res.StoppedBecause = "out_of_gold"
				break
			}

			// One draw per roll, seeded from a counter that only moves forward,
			// so a retried request cannot re-roll for a better tier. type_id is
			// mixed in as well: without it the same (player, seq, slot) hands
			// all three soldier types the identical uniform, and an endpoint
			// that rolls in a loop is exactly where that would become
			// observable.
			rng := game.SeedForString(d.ShopSecret, playerID.String(),
				uint64(wantSeq), uint64(slotIndex), uint64(res.Rolls),
				hashString(typeID), 0xA11CE)
			tier = items.RollTier(d.Config, rng, t.Weights, luck, int(p.Level))

			res.Rolls++
			res.GoldSpent += perRoll
			if r := d.Config.TierRank(tier); r > bestRank {
				bestRank = r
				res.BestTier = tier
			}
			if d.Config.TierRank(tier) >= targetRank {
				res.HitTarget = true
				res.StoppedBecause = "hit_target"
				break
			}
		}
		if res.StoppedBecause == "" {
			res.StoppedBecause = "roll_limit"
		}
		if res.Rolls == 0 {
			return ErrNotEnoughGold
		}

		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: res.GoldSpent, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}

		// Only the last roll is kept. That IS the manual loop's outcome, and
		// storing the intermediates would mean writing thirty soldiers to hold
		// one.
		s, err := q.UpsertSoldier(ctx, sqlcdb.UpsertSoldierParams{
			PlayerID: playerID, SlotIndex: int32(slotIndex), TypeID: typeID, Tier: tier,
			Level: p.Level, Name: t.Name, RolledConfigVersion: int32(d.Config.Version),
		})
		if err != nil {
			return fmt.Errorf("upsert soldier: %w", err)
		}

		// One row for the whole run: the batch is the action the player took,
		// and the ledger should read the way the game was played.
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -res.GoldSpent, BalanceAfter: after.Gold,
			Reason: "recruit", RefID: strPtr(s.ID.String()),
		}); err != nil {
			return fmt.Errorf("ledger: %w", err)
		}

		res.FinalTier = tier
		res.AppliedThrough = wantSeq
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Army, err = d.GetArmy(ctx, playerID)
	return res, err
}

// hashString folds a short identifier into the seed material.
//
// FNV-1a by hand rather than hash/fnv: this value is baked into a seed that must
// produce the same soldier on every server, in every Go version, forever.
func hashString(s string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}
