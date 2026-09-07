package gameconfig

import (
	"fmt"
	"math"
	"strings"
)

// Validate rejects a bundle that would break the game. It runs on the embedded
// seed at startup and, crucially, on every candidate the admin panel tries to
// publish — a bad publish must fail before it reaches players, not after.
// How much experience per energy must improve from the first job to the last.
// Not a design target -- a floor below which the ladder stops being a ladder.
// The experience-per-energy ladder has a floor AND a ceiling, because it has
// been wrong in both directions and each mistake cost the game its pacing.
//
// Too flat (1.3x, the first shipped curve): gold per energy rises 13.3x while a
// level costs about 400x more, so every rung earned gold faster and levels
// slower and progression flattened into a wall — 700 days to the cap for a
// three-sessions-a-day player.
//
// Too steep (5.5x, the correction): landing on top of a doubled energy budget it
// put the cap at 22 days for a five-a-day player against a design target of 91.
//
// The shipped ladder rises 2.1x, which puts a casual player at the cap around
// day 82. Measure with scripts/pace.py before moving either bound.
const (
	minXPERamp = 1.8
	maxXPERamp = 3.5
)

func (b *Bundle) Validate() error {
	var p []string

	// --- jobs ---
	if len(b.Jobs.Jobs) == 0 {
		p = append(p, "no collect jobs defined")
	}
	seenOrder := map[int]bool{}
	for _, j := range b.Jobs.Jobs {
		switch {
		case j.ID == "":
			p = append(p, "a job has an empty id")
		case j.EnergyCost <= 0:
			p = append(p, fmt.Sprintf("job %q: energy_cost must be positive", j.ID))
		case j.BaseGold <= 0:
			p = append(p, fmt.Sprintf("job %q: base_gold must be positive", j.ID))
		case j.BaseXP <= 0:
			p = append(p, fmt.Sprintf("job %q: base_xp must be positive", j.ID))
		case j.UnlockLevel < 1:
			p = append(p, fmt.Sprintf("job %q: unlock_level must be at least 1", j.ID))
		case j.UnlockLevel > b.Progression.LevelCap:
			p = append(p, fmt.Sprintf("job %q: unlock_level %d exceeds the level cap %d — it would never unlock",
				j.ID, j.UnlockLevel, b.Progression.LevelCap))
		}
		if seenOrder[j.Order] {
			p = append(p, fmt.Sprintf("job %q: duplicate order %d", j.ID, j.Order))
		}
		seenOrder[j.Order] = true
	}

	// At least one job must be available at level 1, or a new player cannot act.
	if len(b.JobsForLevel(1)) == 0 {
		p = append(p, "no job unlocks at level 1 — a new player would have nothing to do")
	}

	// Gold per energy must not decrease as jobs unlock, or unlocking a job is a
	// downgrade and the ladder stops meaning anything.
	var prev float64
	var prevName string
	for _, j := range b.jobsAsc {
		gpe := float64(j.BaseGold) / float64(j.EnergyCost)
		if prev > 0 && gpe < prev {
			p = append(p, fmt.Sprintf(
				"job %q has worse gold/energy (%.2f) than the earlier %q (%.2f) — unlocking it would be a downgrade",
				j.ID, gpe, prevName, prev))
		}
		prev, prevName = gpe, j.ID
	}

	// Experience per energy has to climb too, and by enough to matter.
	//
	// This is the check that would have caught the curve that shipped: gold per
	// energy rose 13.3x across the ladder while experience rose 1.3x, and the
	// experience a level costs rises about 400x. Every rung therefore earned gold
	// faster and levels slower, and progression flattened into a wall that took a
	// three-sessions-a-day player 700 days to reach the cap.
	var prevXPE float64
	var prevXPEName string
	var firstXPE, lastXPE float64
	for _, j := range b.jobsAsc {
		xpe := float64(j.BaseXP) / float64(j.EnergyCost)
		if firstXPE == 0 {
			firstXPE = xpe
		}
		lastXPE = xpe
		if prevXPE > 0 && xpe < prevXPE {
			p = append(p, fmt.Sprintf(
				"job %q has worse xp/energy (%.2f) than the earlier %q (%.2f) — levelling would slow down as you climb",
				j.ID, xpe, prevXPEName, prevXPE))
		}
		prevXPE, prevXPEName = xpe, j.ID
	}
	if firstXPE > 0 {
		ramp := lastXPE / firstXPE
		if ramp < minXPERamp {
			p = append(p, fmt.Sprintf(
				"xp/energy only rises %.1fx across the ladder (%.2f to %.2f); below %.1fx the level curve flattens into a wall",
				ramp, firstXPE, lastXPE, minXPERamp))
		}
		if ramp > maxXPERamp {
			p = append(p, fmt.Sprintf(
				"xp/energy rises %.1fx across the ladder (%.2f to %.2f); above %.1fx the late game levels faster than it earns and the cap arrives in weeks",
				ramp, firstXPE, lastXPE, maxXPERamp))
		}
	}

	// --- milestones ---
	var lastBP int64 = -1
	for _, m := range b.Jobs.Milestones {
		if m.Collects <= 0 {
			p = append(p, "a milestone has a non-positive collect threshold")
		}
		if m.BonusBP <= lastBP {
			p = append(p, fmt.Sprintf("milestone at %d collects does not improve on the previous bonus", m.Collects))
		}
		lastBP = m.BonusBP
	}

	// --- progression ---
	if b.Progression.LevelCap < 1 {
		p = append(p, "level_cap must be at least 1")
	}

	// The pool must hold at least an hour of regeneration.
	//
	// Otherwise the regen rate is a number that only matters to somebody checking
	// in more often than it takes to fill, and everyone else's extra minutes are
	// discarded on arrival. A 60-point pool at one a minute filled in half an
	// hour, so halving the regen period changed a three-sessions-a-day player's
	// daily energy by exactly zero.
	if e := b.Progression.Energy; e.RegenBaseSeconds > 0 {
		perHour := 3600 / e.RegenBaseSeconds
		if e.BaseMax < perHour {
			p = append(p, fmt.Sprintf(
				"energy base_max %d holds less than one hour of regen (%d at one per %ds) — the regen rate would not reach anyone who checks in less often",
				e.BaseMax, perHour, e.RegenBaseSeconds))
		}
	}
	for l := 1; l < b.Progression.LevelCap; l++ {
		if b.levelByIx[l].Level != l {
			p = append(p, fmt.Sprintf("progression is missing level %d", l))
			break
		}
		if b.levelByIx[l].XPToNext <= 0 {
			p = append(p, fmt.Sprintf("level %d has a non-positive xp_to_next — levelling would stall or loop", l))
			break
		}
	}

	// --- store ---
	//
	// A diamond price of zero is not "free", it is a field the generator was not
	// re-run for. Reforge shipped at one gold that way; nothing in the store may
	// ship at nothing.
	for _, price := range []struct {
		name string
		v    int64
	}{
		{"energy_refill_diamonds", b.Progression.Store.EnergyRefillDiamonds},
		{"shield_diamonds", b.Progression.Store.ShieldDiamonds},
		{"rename_diamonds", b.Progression.Store.RenameDiamonds},
	} {
		if price.v <= 0 {
			p = append(p, fmt.Sprintf("store.%s must be positive — zero would make it free", price.name))
		}
	}

	// --- energy ---
	e := b.Progression.Energy
	if e.BaseMax <= 0 {
		p = append(p, "energy.base_max must be positive")
	}
	if e.RegenBaseSeconds <= 0 {
		p = append(p, "energy.regen_base_seconds must be positive — zero would regenerate infinite energy")
	}
	// The regen cap is the single ceiling on the whole gold supply. Without it,
	// stacked bonuses make daily income unbounded.
	if e.RegenBonusCapBP < 0 || e.RegenBonusCapBP > 20000 {
		p = append(p, "energy.regen_bonus_cap_bp must be between 0 and 20000 (+200%) — it bounds total gold supply")
	}

	// --- tiers ---
	if len(b.Tiers.Tiers) == 0 {
		p = append(p, "no tiers defined")
	}
	seenRank := map[int]bool{}
	var lastMult float64
	for _, t := range b.Tiers.Tiers {
		if seenRank[t.Rank] {
			p = append(p, fmt.Sprintf("tier %q: duplicate rank %d", t.ID, t.Rank))
		}
		seenRank[t.Rank] = true
		if t.StatMult < lastMult {
			p = append(p, fmt.Sprintf("tier %q is weaker than the tier below it", t.ID))
		}
		lastMult = t.StatMult
		if !strings.HasPrefix(t.Color, "#") || len(t.Color) != 7 {
			p = append(p, fmt.Sprintf("tier %q: color must be #rrggbb", t.ID))
		}
	}

	// --- item prices ---
	//
	// A ratio that is missing from the document reads as zero, and zero prices
	// the action at the 1-gold floor rather than refusing to load. That is how a
	// reforge shipped costing one gold: the field was added to the generator and
	// the generator was not re-run, so the published document simply did not
	// have it. Silence is the failure mode worth closing.
	if b.Items.Price.SellRatioBP <= 0 {
		p = append(p, "items price.sell_ratio_bp is zero — selling would pay nothing")
	}
	if b.Items.Price.ReforgeRatioBP <= 0 {
		p = append(p, "items price.reforge_ratio_bp is zero — reforging would be free")
	}
	// Reforging then selling must always lose money, or an item is a gold press.
	// The most a re-roll can add is the full quality span raised to the price
	// exponent; compare that against what the sell pays back.
	if q := b.Items.Quality; q.MinPct > 0 && b.Items.Price.ReforgeRatioBP > 0 {
		mw := float64(100)
		if float64(b.Items.Masterwork.MultPct) > mw {
			mw = float64(b.Items.Masterwork.MultPct)
		}
		swing := (float64(q.MaxPct) * mw / 100) / float64(q.MinPct)
		gain := math.Pow(swing, b.Items.Price.Exponent) * float64(b.Items.Price.SellRatioBP)
		if gain >= float64(b.Items.Price.ReforgeRatioBP) {
			p = append(p, fmt.Sprintf(
				"a reforge costs %d bp of an item's price but could raise its sell value to %.0f bp — reforging to sell would print gold",
				b.Items.Price.ReforgeRatioBP, gain))
		}
	}

	// --- the tier ladder must be strictly ordered in power ---
	//
	// A tier has to MEAN something: a legendary must out-hit an epic, always, or
	// the ladder every card is sorted and coloured by is decoration.
	//
	// That is a relationship between two numbers, and it was broken. An item's
	// stat is tier x quality x masterwork, so the widest a roll can swing is
	// (max quality x masterwork) / min quality. That was 1.15 x 1.15 / 0.85 =
	// 1.556 while the closest two tiers sat 1.35 apart -- so EVERY adjacent pair
	// could invert, and a masterwork epic really did beat a poorly rolled
	// legendary. Whichever side moves, this is the check that catches it.
	q := b.Items.Quality
	mwPct := int64(100)
	if b.Items.Masterwork.MultPct > mwPct {
		mwPct = b.Items.Masterwork.MultPct
	}
	if q.MinPct > 0 {
		// In basis points, to stay integer: swing = maxQ * mw / minQ.
		swingBP := q.MaxPct * mwPct * 10000 / (q.MinPct * 100)
		var prevBP int64
		var prevTier string
		for _, t := range b.Tiers.Tiers {
			bp := b.Items.TierMultBP[t.ID]
			if bp <= 0 {
				p = append(p, fmt.Sprintf("tier %q has no item multiplier", t.ID))
				continue
			}
			if prevBP > 0 {
				gapBP := bp * 10000 / prevBP
				if gapBP <= swingBP {
					p = append(p, fmt.Sprintf(
						"tier %q is only %.3fx tier %q, but a roll can swing %.3fx — a lucky %s would out-hit an unlucky %s",
						t.ID, float64(gapBP)/10000, prevTier, float64(swingBP)/10000, prevTier, t.ID))
				}
			}
			prevBP, prevTier = bp, t.ID
		}
	}

	// stat_mult is what a human reads when reasoning about the ladder, and it is
	// NOT what the game runs on -- tier_mult_bp is. They drifted a whole curve
	// apart once (13.86x against 7.60x at the top) and nothing noticed, because
	// nothing reads stat_mult. Tie them together here so the readable number
	// cannot lie about the real one again.
	for _, t := range b.Tiers.Tiers {
		want := b.Items.TierMultBP[t.ID]
		got := int64(t.StatMult*10000 + 0.5)
		if want > 0 && got != want {
			p = append(p, fmt.Sprintf(
				"tier %q: stat_mult %.2f disagrees with tier_mult_bp %d — the readable ladder must match the one the game runs on",
				t.ID, t.StatMult, want))
		}
	}

	// --- estates ---
	//
	// This section had no checks at all, which is how a holding ladder whose cost
	// grew faster than its yield reached players: every estate up the ladder was
	// a worse investment than the one below it, and the level-55 capstone took
	// 737 hours to pay for itself against the first holding's 283.
	t := b.Estates.Tax
	if t.BasePerHourMilli <= 0 {
		p = append(p, "estates tax.base_per_hour_milli must be positive — passive income would be dead")
	}
	if t.GrowthBP <= 10000 {
		p = append(p, fmt.Sprintf(
			"estates tax.growth_bp is %d; at or below 10000 idle income shrinks as you level", t.GrowthBP))
	}

	var prevPayback float64
	var prevHolding string
	for _, h := range b.Estates.Holdings {
		if h.MaxLevel <= 0 {
			p = append(p, fmt.Sprintf("holding %q has a non-positive max_level", h.ID))
			continue
		}
		if len(h.Costs) < h.MaxLevel {
			p = append(p, fmt.Sprintf(
				"holding %q has %d costs for %d levels — the last levels could never be bought",
				h.ID, len(h.Costs), h.MaxLevel))
		}
		if h.TaxMilliPerHourPerLevel <= 0 {
			p = append(p, fmt.Sprintf("holding %q yields nothing per level", h.ID))
			continue
		}

		// Payback in hours at the holding's full yield. It must SHORTEN up the
		// ladder, or the estates a player waits longest to unlock are the ones
		// least worth building.
		var total int64
		for i := 0; i < h.MaxLevel && i < len(h.Costs); i++ {
			total += h.Costs[i]
		}
		payback := float64(total) / (float64(h.TaxMilliPerHourPerLevel) / 1000 * float64(h.MaxLevel))
		if prevPayback > 0 && payback > prevPayback {
			p = append(p, fmt.Sprintf(
				"holding %q pays for itself in %.0fh, worse than the earlier %q at %.0fh — later estates must be better investments, not worse",
				h.ID, payback, prevHolding, prevPayback))
		}
		prevPayback, prevHolding = payback, h.ID
	}

	// The tax bonus is the one percentage bucket that never passes through
	// economy.ApplyBucket, so its ceiling cannot be enforced there. Reject a
	// config that could exceed it rather than silently truncating at read time.
	var taxBP int64
	for _, u := range b.Estates.Upgrades {
		if u.Bucket == BucketTaxIncome {
			taxBP += u.PerLevel * int64(u.MaxLevel)
		}
	}
	for _, u := range b.Kingdoms.Upgrades {
		if u.Bucket == BucketTaxIncome {
			taxBP += u.PerLevel * int64(u.MaxLevel)
		}
	}
	if taxBP > MaxTaxIncomeBP {
		p = append(p, fmt.Sprintf(
			"tax_income_bp reaches %d across family and kingdom upgrades, over the %d ceiling — passive income would outrun playing",
			taxBP, MaxTaxIncomeBP))
	}

	if len(p) > 0 {
		return fmt.Errorf("invalid game config:\n  - %s", strings.Join(p, "\n  - "))
	}
	return nil
}
