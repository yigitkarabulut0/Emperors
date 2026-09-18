package gameconfig

import (
	"fmt"
	"math"
)

// The hunt, the forge and the talents, held to their own rules (Wave 7).

func (b *Bundle) validateHunt() []string {
	var p []string
	h := b.Hunt
	where := "hunt"

	if h.Section == "" || !b.HasSection(h.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if len(h.Slots) == 0 {
		p = append(p, where+".slots is empty, so no lord could ever send anybody")
	}
	last := 0
	lastLevel := int64(0)
	for i, s := range h.Slots {
		if s.Level < lastLevel {
			p = append(p, fmt.Sprintf("%s.slots[%d] opens at level %d, before the one above it", where, i, s.Level))
		}
		if s.Slots <= last {
			p = append(p, fmt.Sprintf("%s.slots[%d] is %d, after %d: they must rise", where, i, s.Slots, last))
		}
		lastLevel, last = s.Level, s.Slots
	}
	if h.TierShareBP <= 0 || h.TierShareBP > 10000 {
		p = append(p, fmt.Sprintf("%s.tier_share_bp is %d, outside 1..10000: a rank must be worth "+
			"something on the road, and never the whole ladder", where, h.TierShareBP))
	}
	if h.SpreadBP < 0 || h.SpreadBP >= 10000 {
		p = append(p, fmt.Sprintf("%s.spread_bp is %d: the roll is a share either side of the figure", where, h.SpreadBP))
	}
	if h.RecallPays {
		p = append(p, where+".recall_pays is true: a reward that survives a recall is a reward taken by cancelling")
	}
	if len(h.Fields) == 0 {
		p = append(p, where+" has no fields")
	}
	lastHours, lastWages := int64(0), int64(0)
	for i := range h.Fields {
		f := h.Fields[i]
		fw := fmt.Sprintf("%s.fields[%s]", where, f.ID)
		if f.ID == "" || f.Name == "" {
			p = append(p, fw+" needs an id and a name")
		}
		if f.Hours <= 0 || f.Hours > 24 {
			p = append(p, fmt.Sprintf("%s.hours is %d, outside a day", fw, f.Hours))
		}
		if f.Hours <= lastHours {
			p = append(p, fmt.Sprintf("%s is %dh, after %dh: the fields run from near to far", fw, f.Hours, lastHours))
		}
		if f.GoldWages <= 0 && f.XPWages <= 0 {
			p = append(p, fw+" pays nothing, so nobody would ever be sent there")
		}
		if f.GoldWages <= lastWages {
			p = append(p, fmt.Sprintf("%s pays %d wages, after %d: a longer road must pay more",
				fw, f.GoldWages, lastWages))
		}
		// An hour away must never beat an hour played. Wages ARE energy, so the
		// comparison is direct: what a field pays for an hour against the
		// energy a lord makes in an hour at the regeneration the game allows.
		perHour := f.GoldWages * 10000 / f.Hours
		if cap := b.regenEnergyPerHour() * 10000; perHour > cap/2 {
			p = append(p, fmt.Sprintf("%s pays %.1f energy an hour and a lord makes about %.1f "+
				"just by being alive: an expedition may not be half a day's play",
				fw, float64(perHour)/10000, float64(cap)/10000))
		}
		if f.ItemChanceBP < 0 || f.ItemChanceBP > 10000 {
			p = append(p, fmt.Sprintf("%s.item_chance_bp is %d, outside 0..10000", fw, f.ItemChanceBP))
		}
		if f.ItemChanceBP > 0 && b.Items.TierMultBP[f.ItemTier] == 0 {
			p = append(p, fmt.Sprintf("%s.item_tier %q is not a rank", fw, f.ItemTier))
		}
		lastHours, lastWages = f.Hours, f.GoldWages
	}
	return p
}

// regenEnergyPerHour is what a lord makes by being alive, at the base rate.
func (b *Bundle) regenEnergyPerHour() int64 {
	s := b.Progression.Energy.RegenBaseSeconds
	if s <= 0 {
		return 0
	}
	return 3600 / s
}

func (b *Bundle) validateForge() []string {
	var p []string
	f := b.Forge
	where := "forge"

	if f.Section == "" || !b.HasSection(f.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if f.Pieces < 2 {
		p = append(p, fmt.Sprintf("%s.pieces is %d: a forge that takes one piece is a rename", where, f.Pieces))
	}
	if len(f.Tiers) == 0 {
		p = append(p, where+".tiers is empty, so nothing could be forged")
	}
	order := b.TierIDsAscending()
	top := len(order) - 1
	for _, t := range f.Tiers {
		i := b.TierRank(t) - 1
		if i < 0 {
			p = append(p, fmt.Sprintf("%s.tiers has %q, which is not a rank", where, t))
			continue
		}
		if i >= top {
			p = append(p, fmt.Sprintf("%s.tiers has %q, and there is nothing above it to forge into", where, t))
		}
	}
	if f.Quality.MinPct <= 0 || f.Quality.MaxPct < f.Quality.MinPct {
		p = append(p, where+".quality is not a range")
	}
	if !f.KeepsHighestILvl {
		p = append(p, where+".keeps_highest_ilvl is false: the piece takes the best MARK of the "+
			"three, and the rule is a number in the document rather than a sentence in a comment")
	}
	if f.MasterworkChanceBP < 0 || f.MasterworkChanceBP > 10000 {
		p = append(p, fmt.Sprintf("%s.masterwork_chance_bp is %d, outside 0..10000", where, f.MasterworkChanceBP))
	}

	// The fee alone settles it: a forged piece sells for sell_ratio of the rank
	// above's price, and the forge charges fee_bp of that same price. While the
	// fee is the larger share, no curve and no rank can make the round trip pay
	// -- and the loop below proves it rung by rung and slot by slot as well.
	if f.FeeBPOfNextPrice <= b.Items.Price.SellRatioBP {
		p = append(p, fmt.Sprintf("%s.fee_bp_of_next_price is %d and a piece sells for %d bp of the "+
			"very same price: the fee must be the larger share, or forging and selling would "+
			"pay for itself", where, f.FeeBPOfNextPrice, b.Items.Price.SellRatioBP))
	}

	// The rule that keeps the forge from being a mint: forging and selling must
	// lose money, at every rung, for every slot.
	//
	// Selling the three pieces pays 3 * sell(T). Forging pays the fee and then
	// sells one piece of the rank above for sell(T+1). If sell(T+1) ever came
	// out above fee + 3*sell(T), a lord could forge for profit -- and because
	// the fee is a share of the NEXT rank's price, that is a relationship
	// between two numbers rather than a hope, so it is checked here.
	for _, t := range f.Tiers {
		i := b.TierRank(t) - 1
		if i < 0 || i >= top {
			continue
		}
		next := order[i+1]
		for slot := range b.Items.SlotBase {
			// A middling mark, which is where the ratio is tightest.
			const ilvl = 30
			cur := b.shopPrice(slot, t, ilvl)
			up := b.shopPrice(slot, next, ilvl)
			sell := func(v int64) int64 { return v * b.Items.Price.SellRatioBP / 10000 }
			fee := up * f.FeeBPOfNextPrice / 10000
			paid := fee + int64(f.Pieces)*sell(cur)
			if sell(up) >= paid {
				p = append(p, fmt.Sprintf("%s: forging %s %s into %s and selling it pays %d for %d "+
					"spent -- the forge would print gold", where, t, slot, next, sell(up), paid))
			}
		}
	}
	return p
}

// shopPrice mirrors items.BuyPrice for the validator's own use: gameconfig
// cannot import the game packages, and the forge's proof needs a price.
func (b *Bundle) shopPrice(slot, tier string, ilvl int64) int64 {
	base, ok := b.Items.SlotBase[slot]
	if !ok {
		return 0
	}
	tierBP := b.Items.TierMultBP[tier]
	levelBP := 10000 + b.Items.LevelMultPerIlvlBP*ilvl
	scale := func(v int64) int64 {
		if v == 0 {
			return 0
		}
		num := v * tierBP * levelBP * 100 * 100
		den := int64(10000) * 10000 * 100 * 100
		return (num + den/2) / den
	}
	attack, defense, speed := scale(base.Attack), scale(base.Defense), scale(base.Speed)
	power := attack + defense + speed*b.Items.SpeedPowerWeightBP/10000
	if power <= 0 {
		return 1
	}
	pr := b.Items.Price
	mult := float64(b.Items.TierPriceMultBP[tier]) / 10000.0
	return int64(math.Round(pr.Coef * math.Pow(float64(power), pr.Exponent) * mult))
}

func (b *Bundle) validateTalents() []string {
	var p []string
	t := b.Talents
	where := "talents"

	if t.Section == "" || !b.HasSection(t.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if t.FirstLevel <= 0 || t.FirstLevel > int64(b.Progression.LevelCap) {
		p = append(p, fmt.Sprintf("%s.first_level is %d, which is not a level", where, t.FirstLevel))
	}
	if t.LevelsPerPoint <= 0 {
		p = append(p, where+".levels_per_point is zero, so a lord would be given every point at once")
	}
	if len(t.TierGates) == 0 {
		p = append(p, where+".tier_gates is empty: a tree with no depth is a list")
	}
	last := -1
	for i, g := range t.TierGates {
		if g < last {
			p = append(p, fmt.Sprintf("%s.tier_gates[%d] is %d, under the one before it", where, i, g))
		}
		last = g
	}
	if t.Respec.BaseGold <= 0 || t.Respec.MaxGold < t.Respec.BaseGold {
		p = append(p, where+".respec must cost gold, and its ceiling must be above its floor")
	}
	if t.Respec.StepBP <= 10000 {
		p = append(p, where+".respec.step_bp does not rise: changing your mind must cost more each time")
	}
	if len(t.Branches) == 0 {
		p = append(p, where+" has no branches")
		return p
	}

	// Every rank feeds a channel the game already has, and the totals must stay
	// inside the ceilings the rest of the game is bounded by. The tax bucket is
	// the sharp one: it is a stored RATE and never passes through ApplyBucket,
	// so nothing clamps it at a call site.
	perBucket := map[string]int64{}
	seen := map[string]bool{}
	ranks := 0
	for bi := range t.Branches {
		br := &t.Branches[bi]
		if br.ID == "" || br.Name == "" {
			p = append(p, where+" has a branch with no name")
		}
		tiersSeen := map[int]bool{}
		for ti := range br.Talents {
			x := br.Talents[ti]
			xw := fmt.Sprintf("%s.%s.%s", where, br.ID, x.ID)
			if x.ID == "" || x.Name == "" || x.Blurb == "" {
				p = append(p, xw+" needs an id, a name and a line saying what it does")
			}
			if seen[x.ID] {
				p = append(p, xw+" is named twice")
			}
			seen[x.ID] = true
			if x.Ranks < 1 || x.Ranks > 10 {
				p = append(p, fmt.Sprintf("%s has %d ranks, outside 1..10", xw, x.Ranks))
			}
			if x.PerRank <= 0 {
				p = append(p, xw+" is worth nothing a rank")
			}
			if x.Tier < 1 || x.Tier > len(t.TierGates) {
				p = append(p, fmt.Sprintf("%s is on tier %d, and the tree has %d", xw, x.Tier, len(t.TierGates)))
			}
			if tiersSeen[x.Tier] {
				p = append(p, fmt.Sprintf("%s shares tier %d with another talent in its branch: "+
					"a tier is a rung, not a shelf", xw, x.Tier))
			}
			tiersSeen[x.Tier] = true
			if !isTalentBucket(x.Bucket) {
				p = append(p, fmt.Sprintf("%s feeds %q, which is not a channel the game already has: "+
					"a talent that invents one is a second place a percentage is applied", xw, x.Bucket))
			}
			perBucket[x.Bucket] += x.PerRank * int64(x.Ranks)
			ranks += x.Ranks
		}
	}
	if ranks <= int(t.PointsAt(int64(b.Progression.LevelCap), int64(b.Progression.Legacy.MaxStacks))) {
		p = append(p, fmt.Sprintf("%s has %d ranks and a lord is given %d points: a tree you can fill "+
			"is not a choice", where, ranks, t.PointsAt(int64(b.Progression.LevelCap), int64(b.Progression.Legacy.MaxStacks))))
	}

	// The tax ceiling, with everything else that reaches it.
	tax := perBucket[BucketTaxIncome]
	for _, u := range b.Estates.Upgrades {
		if u.Bucket == BucketTaxIncome {
			tax += u.PerLevel * int64(u.MaxLevel)
		}
	}
	for _, u := range b.Kingdoms.Upgrades {
		if u.Bucket == BucketTaxIncome {
			tax += u.PerLevel * int64(u.MaxLevel)
		}
	}
	if tax > MaxTaxIncomeBP {
		p = append(p, fmt.Sprintf("%s: the tax bucket reaches %d bp with the talents in it and the "+
			"ceiling is %d -- tax is a stored rate and never passes through ApplyBucket, so nothing "+
			"else would stop it", where, tax, MaxTaxIncomeBP))
	}
	if luck := perBucket[BucketLuck]; luck > MaxLuckBP {
		p = append(p, fmt.Sprintf("%s: the luck the tree gives is %d bp and the ceiling is %d", where, luck, MaxLuckBP))
	}
	return p
}

// isTalentBucket reports a channel a talent may feed: the ones the Family's own
// upgrades use, plus the storehouse's minutes.
func isTalentBucket(id string) bool {
	switch id {
	case BucketCollectIncome, BucketTaxIncome, BucketXP, BucketEnergyRegen,
		BucketMaxEnergyFlat, BucketSoldierAtk, BucketSoldierDef, BucketSoldierSpd,
		BucketShopDiscount, BucketStealCap, BucketRansom, BucketLuck,
		BucketStorehouseMinutes:
		return true
	}
	return false
}
