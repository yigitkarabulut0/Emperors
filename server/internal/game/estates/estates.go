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

	TaxMilliPerHour   int64
	OfflineCapSeconds int64
}

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

		switch u.Bucket {
		case gameconfig.BucketCollectIncome:
			e.Bonuses.Add(economy.BucketCollectIncome, amount)
		case gameconfig.BucketXP:
			e.Bonuses.Add(economy.BucketXPGain, amount)
		case gameconfig.BucketEnergyRegen:
			e.Bonuses.Add(economy.BucketEnergyRegen, amount)
		case gameconfig.BucketTaxIncome:
			taxIncomeBP += amount
			titheLevel = int(lv)
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

	if taxIncomeBP > 0 {
		perHour = perHour * (10000 + taxIncomeBP) / 10000
	}
	return perHour
}

// TaxState is the stored accrual, mirroring how energy works.
type TaxState struct {
	Milli     int64
	UpdatedAt time.Time
}

// SettleTax advances accrual to now, clamped by the offline cap.
func SettleTax(s TaxState, ratePerHour, capSeconds int64, now time.Time) TaxState {
	if ratePerHour <= 0 {
		return TaxState{Milli: s.Milli, UpdatedAt: now}
	}
	elapsed := int64(now.Sub(s.UpdatedAt).Seconds())
	if elapsed <= 0 {
		return s
	}
	// The cap is what stops uncollected tax becoming an infinite, unstealable
	// bank. Time past it is simply lost, which is the pressure to come back.
	if elapsed > capSeconds {
		elapsed = capSeconds
	}
	return TaxState{Milli: s.Milli + ratePerHour*elapsed/3600, UpdatedAt: now}
}

// Whole returns claimable gold.
func Whole(s TaxState) int64 { return s.Milli / 1000 }

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

	// The tax rate is not a bucket, so a kingdom's Royal Treasury has to be
	// folded back into the rate rather than added to a total afterwards.
	if taxIncomeBP > 0 {
		e.TaxMilliPerHour = e.TaxMilliPerHour * (10000 + taxIncomeBP) / 10000
	}
}
