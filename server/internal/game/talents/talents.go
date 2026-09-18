// Package talents is the pure half of the talent tree: what a lord has been
// given, what they may spend it on, and what the spending does.
//
// A point every three levels from ten, and one more for each Legacy: twenty-
// seven points against fifty-one ranks, so the tree is a choice and never a
// checklist. What a rank does, it does through a channel the game ALREADY has --
// the same buckets the Family's upgrades feed -- so a talent is another way to
// earn a percentage and never a second place one is applied.
//
// Pure like the rest of internal/game.
package talents

import (
	"errors"
	"fmt"

	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var (
	// ErrUnknown is a talent id the tree does not have.
	ErrUnknown = errors.New("no such talent")
	// ErrMaxRanks is a talent already at its last rank.
	ErrMaxRanks = errors.New("talent already at its last rank")
	// ErrNoPoints is a lord with nothing left to spend.
	ErrNoPoints = errors.New("no talent points left")
	// ErrShut is a tier whose branch has not been paid into deeply enough.
	ErrShut = errors.New("this tier of the branch is not open yet")
)

// Spend is what a lord has bought: talent id -> ranks.
type Spend map[string]int

// Points is how many points a lord of this level with this many Legacies has
// been given, in all.
func Points(cfg *gameconfig.Bundle, level, legacy int64) int64 {
	return cfg.Talents.PointsAt(level, legacy)
}

// Bought is how many points a spend has used.
func Bought(s Spend) int64 {
	var n int64
	for _, r := range s {
		n += int64(r)
	}
	return n
}

// Left is what a lord still has to spend. Never negative: a tree that shrank
// under a lord -- a rank removed from the balance -- must not read as debt.
func Left(cfg *gameconfig.Bundle, s Spend, level, legacy int64) int64 {
	n := Points(cfg, level, legacy) - Bought(s)
	if n < 0 {
		return 0
	}
	return n
}

// InBranch is how many ranks a lord has bought inside one branch, which is what
// its tiers open on.
func InBranch(cfg *gameconfig.Bundle, s Spend, branchID string) int {
	br := cfg.Talents.Branch(branchID)
	if br == nil {
		return 0
	}
	n := 0
	for _, x := range br.Talents {
		n += s[x.ID]
	}
	return n
}

// Open reports whether a talent may be bought into at all: its tier's gate is
// paid for. A tier is a rung, and the gate is what makes the three branches a
// decision rather than a shopping list.
func Open(cfg *gameconfig.Bundle, s Spend, id string) bool {
	x, br := cfg.Talents.Talent(id)
	if x == nil {
		return false
	}
	return InBranch(cfg, s, br.ID) >= cfg.Talents.TierOpensAt(x.Tier)
}

// CanBuy says whether a lord may buy one more rank of a talent, and why not.
func CanBuy(cfg *gameconfig.Bundle, s Spend, level, legacy int64, id string) error {
	x, br := cfg.Talents.Talent(id)
	if x == nil {
		return ErrUnknown
	}
	if s[id] >= x.Ranks {
		return ErrMaxRanks
	}
	if Left(cfg, s, level, legacy) < 1 {
		return ErrNoPoints
	}
	if need := cfg.Talents.TierOpensAt(x.Tier); InBranch(cfg, s, br.ID) < need {
		return fmt.Errorf("%w: %s needs %d points in %s", ErrShut, x.Name, need, br.Name)
	}
	return nil
}

// RespecCost is what taking it all back costs this time: it doubles with each
// time a lord has done it, to a ceiling, so changing your mind is a decision and
// not a habit.
func RespecCost(cfg *gameconfig.Bundle, done int64) int64 {
	r := cfg.Talents.Respec
	cost := r.BaseGold
	for i := int64(0); i < done; i++ {
		cost = cost * r.StepBP / 10000
		if cost >= r.MaxGold {
			return r.MaxGold
		}
	}
	if cost > r.MaxGold {
		return r.MaxGold
	}
	return cost
}

// Apply folds a lord's talents into their effects.
//
// The same shape as estates.ApplyKingdom and for the same reason: a percentage
// belongs in a bucket, additively, and is applied once by economy.ApplyBucket
// wherever it is spent. The tax lane is the sharp one -- it is a stored RATE and
// never passes through ApplyBucket -- so it is recomputed from the SUM here, the
// way a kingdom's Royal Treasury is, rather than multiplied onto a finished rate.
func Apply(cfg *gameconfig.Bundle, e *estates.Effects, level int64,
	holdingLevels map[string]int, s Spend) {

	var taxIncomeBP int64
	for bi := range cfg.Talents.Branches {
		br := &cfg.Talents.Branches[bi]
		for ti := range br.Talents {
			x := &br.Talents[ti]
			ranks := s[x.ID]
			if ranks <= 0 {
				continue
			}
			if ranks > x.Ranks {
				ranks = x.Ranks
			}
			amount := x.PerRank * int64(ranks)

			switch x.Bucket {
			case gameconfig.BucketCollectIncome:
				e.Bonuses.Add(economy.BucketCollectIncome, amount)
			case gameconfig.BucketXP:
				e.Bonuses.Add(economy.BucketXPGain, amount)
			case gameconfig.BucketEnergyRegen:
				e.Bonuses.Add(economy.BucketEnergyRegen, amount)
			case gameconfig.BucketTaxIncome:
				taxIncomeBP += amount
			case gameconfig.BucketMaxEnergyFlat:
				e.MaxEnergyFlat += amount
			case gameconfig.BucketShopDiscount:
				e.ShopDiscount += amount
			case gameconfig.BucketStealCap:
				e.StealCapBP += amount
			case gameconfig.BucketRansom:
				e.RansomBP += amount
			case gameconfig.BucketSoldierAtk:
				e.SoldierAtkBP += amount
			case gameconfig.BucketSoldierDef:
				e.SoldierDefBP += amount
			case gameconfig.BucketSoldierSpd:
				e.SoldierSpdBP += amount
			case gameconfig.BucketLuck:
				e.LuckBP += amount
			case gameconfig.BucketStorehouseMinutes:
				// The one channel the tree brought with it: minutes on the
				// storehouse, which is estates' own number and not a bucket.
				e.OfflineCapSeconds += amount * 60
			}
		}
	}
	if taxIncomeBP > 0 {
		e.TaxIncomeBP += taxIncomeBP
		e.TaxMilliPerHour = estates.TaxRate(cfg, level, holdingLevels, e.TaxIncomeBP)
	}
}
