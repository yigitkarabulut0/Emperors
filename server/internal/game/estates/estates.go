// Package estates derives the effects of Family upgrades and Territory
// holdings: bonus buckets, energy ceilings, and the passive tax rate.
//
// Pure, like the rest of internal/game. Time arrives as a parameter.
package estates

import (
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Effects is everything a player's estate does for them.
type Effects struct {
	Bonuses economy.Bonuses

	MaxEnergyFlat int64
	ShopDiscount  int64
	StealCapBP    int64
	RansomBP      int64
	SoldierAtkBP  int64
	SoldierDefBP  int64
	SoldierSpdBP  int64
	// A bonus on the tier ladder's LEVEL coefficient, not a scaler on an amount.
	//
	// Deliberately not in economy.Bonuses: ApplyBucket's contract is "scale an
	// amount, clamped to that bucket's cap", and luck scales a distribution
	// parameter instead. A bucket whose ApplyBucket is never called is a cap
	// that is not a cap.
	LuckBP int64

	// Per HOUR, not per second. Dividing to a per-second rate loses so much to
	// integer truncation that a whole wheat farm level changed nothing: at
	// level 5 the base is 29,904 milli/hour, which floors to 8 milli/second
	// either way. Accrual multiplies by elapsed seconds and divides by 3600 at
	// the end, so the precision survives.
	ReputationBP int64

	// The tax bonus in basis points, kept so ApplyKingdom can ADD a kingdom's
	// Royal Treasury to it and recompute the rate once. Without it the kingdom
	// node had nothing to add to and multiplied the finished rate a second time,
	// which is the compounding the additive-bucket rule exists to forbid.
	TaxIncomeBP int64

	TaxMilliPerHour   int64
	OfflineCapSeconds int64
}

// TitheBarn is the Family upgrade whose levels lengthen the storehouse: 12
// minutes each (estates.tax.offline_cap_per_tithe_level), 12 hours at its top.
const TitheBarn = "tithe_barn"

// Derive folds upgrade and holding levels into their effects.
//
// Every percentage lands in a bucket and is applied once, so upgrades never
// compound with each other and every bucket keeps its hard cap. A maxed Granary
// (+60%), a maxed kingdom bonus (+20%) and a fully mastered job (+30%) come to
// +110% — inside the +150% ceiling, with headroom left for future content.
func Derive(cfg *gameconfig.Bundle, level int64, upgradeLevels, holdingLevels map[string]int) Effects {
	var e Effects
	var taxIncomeBP int64
	titheLevel := 0

	for _, u := range cfg.Estates.Upgrades {
		lv := int64(upgradeLevels[u.ID])
		if lv <= 0 {
			continue
		}
		if lv > int64(u.MaxLevel) {
			lv = int64(u.MaxLevel)
		}
		amount := u.PerLevel * lv
		if u.ID == TitheBarn {
			titheLevel = int(lv)
		}

		switch u.Bucket {
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
		}
	}

	e.TaxIncomeBP = taxIncomeBP
	e.TaxMilliPerHour = TaxRate(cfg, level, holdingLevels, taxIncomeBP)

	t := cfg.Estates.Tax
	e.OfflineCapSeconds = t.OfflineCapSeconds + t.OfflineCapPerTitheLevel*int64(titheLevel)
	return e
}

// TaxRate returns passive income in milli-gold per HOUR.
//
// Deliberately a function of level and estates only — never of Might or
// equipment. Letting gear feed idle income would create a loop where PvP power
// buys income which buys PvP power, and the strong would pull away permanently.
func TaxRate(cfg *gameconfig.Bundle, level int64, holdingLevels map[string]int, taxIncomeBP int64) int64 {
	t := cfg.Estates.Tax

	// Base from level: growth^level, applied iteratively so it stays integer.
	perHour := t.BasePerHourMilli
	for i := int64(0); i < level; i++ {
		perHour = perHour * t.GrowthBP / 10000
	}

	for _, h := range cfg.Estates.Holdings {
		lv := int64(holdingLevels[h.ID])
		if lv <= 0 {
			continue
		}
		if lv > int64(h.MaxLevel) {
			lv = int64(h.MaxLevel)
		}
		perHour += h.TaxMilliPerHourPerLevel * lv
	}

	// The ceiling. Validate refuses a config that could reach past it, so this
	// is defence in depth rather than the only guard -- but tax never passes
	// through economy.ApplyBucket, so without it this bucket has no cap at all.
	if taxIncomeBP > gameconfig.MaxTaxIncomeBP {
		taxIncomeBP = gameconfig.MaxTaxIncomeBP
	}
	if taxIncomeBP > 0 {
		perHour = perHour * (10000 + taxIncomeBP) / 10000
	}
	return perHour
}

// Storehouse is estate income waiting to be carried in: what it holds in
// milli-gold and when that was last settled. Income fills it at the hourly rate
// up to its capacity, and stops there -- the time past it is lost, which is the
// reason to come back. Gold in it cannot be stolen; gold carried out of it into
// the purse can.
type Storehouse struct {
	Milli int64
	At    time.Time
}

// StorehouseCap is how much a storehouse holds: the hourly rate for the cap's
// seconds (8 hours, and 12 minutes more for each Tithe Barn level).
func StorehouseCap(ratePerHour, capSeconds int64) int64 {
	if ratePerHour <= 0 || capSeconds <= 0 {
		return 0
	}
	return ratePerHour * capSeconds / 3600
}

// maxFillMs bounds one settlement's elapsed time. Anything longer only matters
// up to the capacity anyway, and the bound keeps rate x elapsed inside int64.
const maxFillMs = int64(400 * 24 * 3600 * 1000)

// Fill advances a storehouse to now at a rate, up to its capacity. What is
// already over the capacity -- a rate that fell since it filled -- is kept, and
// nothing more is added. The query RefreshStorehouse is the same sum in SQL; the
// integration tests hold the two together.
//
// Both clocks are cut to the microsecond, as Postgres keeps them, and elapsed
// time is floored to the millisecond, as the query floors it, so the two sums
// never differ by a milli.
func Fill(s Storehouse, ratePerHour, capMilli int64, now time.Time) Storehouse {
	now = now.Truncate(time.Microsecond)
	s.At = s.At.Truncate(time.Microsecond)
	elapsed := now.Sub(s.At).Milliseconds()
	if elapsed <= 0 || ratePerHour <= 0 {
		return Storehouse{Milli: s.Milli, At: laterOf(s.At, now)}
	}
	if elapsed > maxFillMs {
		elapsed = maxFillMs
	}
	milli := s.Milli
	if milli < capMilli {
		milli += ratePerHour * elapsed / 3600000
		if milli > capMilli {
			milli = capMilli
		}
	}
	return Storehouse{Milli: milli, At: now}
}

// FullIn is how long a storehouse takes to fill from what it holds, rounded up
// to the whole second so it never reads zero before it is full: zero when it
// is, or when nothing fills it.
func FullIn(milli, ratePerHour, capMilli int64) time.Duration {
	if ratePerHour <= 0 || milli >= capMilli {
		return 0
	}
	ms := ((capMilli-milli)*3600000 + ratePerHour - 1) / ratePerHour
	return time.Duration((ms+999)/1000) * time.Second
}

func laterOf(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// ApplyKingdom folds a kingdom's upgrades into a member's effects.
//
// Kingdom nodes feed the SAME buckets as Family nodes, which is the whole point:
// a maxed Granary (+60%), maxed Royal Granaries (+20%) and a fully mastered job
// (+30%) come to +110%, applied once, inside the +150% bucket cap. If kingdom
// bonuses had their own multiplier they would compound with the family tree and
// the cap would stop meaning anything.
func ApplyKingdom(cfg *gameconfig.Bundle, e *Effects, level int64, kingdomLevels, holdingLevels map[string]int) {
	var taxIncomeBP int64

	for _, u := range cfg.Kingdoms.Upgrades {
		lv := int64(kingdomLevels[u.ID])
		if lv <= 0 {
			continue
		}
		if lv > int64(u.MaxLevel) {
			lv = int64(u.MaxLevel)
		}
		amount := u.PerLevel * lv

		switch u.Bucket {
		case gameconfig.BucketCollectIncome:
			e.Bonuses.Add(economy.BucketCollectIncome, amount)
		case gameconfig.BucketXP:
			e.Bonuses.Add(economy.BucketXPGain, amount)
		case gameconfig.BucketEnergyRegen:
			e.Bonuses.Add(economy.BucketEnergyRegen, amount)
		case gameconfig.BucketSoldierAtk:
			e.SoldierAtkBP += amount
		case gameconfig.BucketSoldierDef:
			e.SoldierDefBP += amount
		case gameconfig.BucketSoldierSpd:
			e.SoldierSpdBP += amount
		case gameconfig.BucketLuck:
			e.LuckBP += amount
		case gameconfig.BucketReputation:
			e.ReputationBP += amount
		case gameconfig.BucketTaxIncome:
			taxIncomeBP += amount
		}
	}

	// Recomputed from the SUM, not multiplied onto the finished rate.
	//
	// Multiplying again made the family tree and the kingdom compound: +30% and
	// +10% came out as x1.43 instead of x1.40, and a Royal Treasury could push
	// the total past MaxTaxIncomeBP because the clamp inside TaxRate had already
	// been applied and passed. Tax is one additive bucket like every other, and
	// it has to be resolved in one place.
	if taxIncomeBP > 0 {
		e.TaxIncomeBP += taxIncomeBP
		e.TaxMilliPerHour = TaxRate(cfg, level, holdingLevels, e.TaxIncomeBP)
	}
}
