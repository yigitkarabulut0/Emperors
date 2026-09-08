// Package items is the pure gear engine: stat derivation, tier rolls, pricing.
//
// Like the rest of internal/game it takes no clock, no database and no context.
// Randomness arrives as a *rand.Rand the caller seeded deterministically, so
// every roll the server makes can be replayed and audited.
package items

import (
	"math"
	"math/rand/v2"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Instance is a rolled item: a definition plus the numbers rolled at acquisition.
//
// Stats are FROZEN at acquisition. Deriving them live from the active config
// would mean a rebalance silently nerfing gear a player already paid for, which
// is the fastest way to lose a paying player's trust.
type Instance struct {
	DefID      string `json:"def_id"`
	Slot       string `json:"slot"`
	Tier       string `json:"tier"`
	Name       string `json:"name"`
	Art        string `json:"art"`
	Ilvl       int64  `json:"ilvl"`
	QualityPct int64  `json:"quality_pct"`
	Masterwork bool   `json:"masterwork"`

	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	Speed   int64 `json:"speed"`
}

// Power is the single number used for pricing and for army strength.
// Speed counts at half weight, which is what makes a horse's lower raw stats a
// real trade rather than a tax.
func (i Instance) Power(cfg *gameconfig.Bundle) int64 {
	return i.Attack + i.Defense + i.Speed*cfg.Items.SpeedPowerWeightBP/10000
}

// Stat derives one stat with integer maths and half-up rounding.
//
// Integer-only on purpose: a float pipeline rounds differently in Go, Python and
// GDScript on exact .5 cases, and "my sword shows 133 on one screen and 132 on
// another" is a bug report nobody enjoys.
func Stat(cfg *gameconfig.Bundle, slot, tier string, ilvl, qualityPct int64, masterwork bool) (attack, defense, speed int64) {
	base, ok := cfg.Items.SlotBase[slot]
	if !ok {
		return 0, 0, 0
	}
	tierBP := cfg.Items.TierMultBP[tier]
	levelBP := 10000 + cfg.Items.LevelMultPerIlvlBP*ilvl

	mwPct := int64(100)
	if masterwork {
		mwPct = cfg.Items.Masterwork.MultPct
	}

	scale := func(v int64) int64 {
		if v == 0 {
			return 0
		}
		num := v * tierBP * levelBP * qualityPct * mwPct
		den := int64(10000) * 10000 * 100 * 100
		return (num + den/2) / den
	}
	return scale(base.Attack), scale(base.Defense), scale(base.Speed)
}

// ClampLuckBP bounds a luck bonus.
//
// -10000 flattens the level term to the base weights, which is the worst a
// player can be made: exactly a level-1 ladder, never worse than the game's own
// floor. +10000 doubles the level coefficient.
func ClampLuckBP(bp int64) int64 {
	if bp > gameconfig.MaxLuckBP {
		return gameconfig.MaxLuckBP
	}
	if bp < -gameconfig.MaxLuckBP {
		return -gameconfig.MaxLuckBP
	}
	return bp
}

// EffectiveLuckCoef applies a player's luck to the config's luck coefficient.
// luckBP == 0 returns base unchanged, so behaviour with no override is exact.
func EffectiveLuckCoef(base float64, luckBP int64) float64 {
	return base * float64(10000+ClampLuckBP(luckBP)) / 10000.0
}

// Roll produces one item of a given slot and tier at an item level.
//
// luckBP tilts quality and the masterwork threshold. It does NOT change how many
// values are drawn from rng, or in what order: shop.go pulls the equipment slot
// from the same stream between RollTier and Roll, so a changed draw count would
// silently reshuffle every shelf in the game.
func Roll(cfg *gameconfig.Bundle, rng *rand.Rand, slot, tier string, ilvl, luckBP int64) Instance {
	defs := cfg.ItemDefsFor(slot, tier)
	if len(defs) == 0 {
		return Instance{}
	}
	def := defs[rng.IntN(len(defs))]

	luckBP = ClampLuckBP(luckBP)

	q := cfg.Items.Quality
	quality := q.MinPct
	if span := q.MaxPct - q.MinPct; span > 0 {
		quality += rng.Int64N(span + 1) // the same single draw as before
	}
	// Luck PULLS the drawn value toward the top of the band rather than adding
	// to it, so the result can never leave [MinPct, MaxPct] -- the range test
	// holds by construction rather than by arithmetic luck. It also saturates:
	// at the maximum bonus it closes half the remaining gap, so no amount of
	// luck ever guarantees a perfect roll.
	switch {
	case luckBP > 0:
		quality += (q.MaxPct - quality) * luckBP / (10000 + luckBP)
	case luckBP < 0:
		quality -= (quality - q.MinPct) * -luckBP / (10000 - luckBP)
	}
	// Scale the THRESHOLD, not the draw: one Int64N as before, a different bar.
	masterwork := rng.Int64N(10000) < cfg.Items.Masterwork.ChanceBP*(10000+luckBP)/10000

	atk, def_, spd := Stat(cfg, slot, tier, ilvl, quality, masterwork)
	return Instance{
		DefID: def.ID, Slot: def.Slot, Tier: def.Tier, Name: def.Name, Art: def.Art,
		Ilvl: ilvl, QualityPct: quality, Masterwork: masterwork,
		Attack: atk, Defense: def_, Speed: spd,
	}
}

// tierWeights is the ONE place the ladder formula lives.
//
// RollTier and TierOdds both call it, so the odds the admin panel previews
// cannot drift from the odds the game actually rolls -- which is the entire
// point of previewing them.
func tierWeights(cfg *gameconfig.Bundle, baseWeights map[string]float64,
	luckCoef float64, level int) ([]string, []float64, float64) {
	tiers := cfg.TierIDsAscending()
	weights := make([]float64, len(tiers))
	var total float64

	lvl := float64(min(level, cfg.Progression.LevelCap))
	for i, id := range tiers {
		w := baseWeights[id] * math.Pow(1+luckCoef*lvl, float64(i))
		weights[i] = w
		total += w
	}
	return tiers, weights, total
}

// TierOdd is one tier's probability, in basis points.
type TierOdd struct {
	Tier string `json:"tier"`
	BP   int64  `json:"bp"`
}

// TierOdds is what an operator sees before committing a luck change: the real
// distribution, from the real formula, at that player's real level.
func TierOdds(cfg *gameconfig.Bundle, baseWeights map[string]float64,
	luckCoef float64, level int) []TierOdd {
	tiers, weights, total := tierWeights(cfg, baseWeights, luckCoef, level)
	out := make([]TierOdd, 0, len(tiers))
	for i, id := range tiers {
		var bp int64
		if total > 0 {
			bp = int64(weights[i] / total * 10000)
		}
		out = append(out, TierOdd{Tier: id, BP: bp})
	}
	return out
}

// RollTier picks a tier from a weighted table.
//
// Weight grows with player level raised to the TIER INDEX, so higher levels
// shift mass up the ladder without ever making commons impossible — which is
// the shape you want, because "no more junk drops" removes the contrast that
// makes a good drop feel good.
func RollTier(cfg *gameconfig.Bundle, rng *rand.Rand, baseWeights map[string]float64, luckCoef float64, level int) string {
	tiers, weights, total := tierWeights(cfg, baseWeights, luckCoef, level)
	if total <= 0 {
		return tiers[0]
	}

	pick := rng.Float64() * total
	for i, w := range weights {
		pick -= w
		if pick <= 0 {
			return tiers[i]
		}
	}
	return tiers[0]
}

// BuyPrice is what the shop charges.
//
// This is the one place a float appears in the economy. It is safe because a
// price is computed once and immediately rounded to an integer that is charged
// and stored — it is never accumulated, so there is no drift to accumulate.
func BuyPrice(cfg *gameconfig.Bundle, item Instance, discountBP int64) int64 {
	p := cfg.Items.Price
	power := float64(item.Power(cfg))
	if power <= 0 {
		return 1
	}
	tierMult := float64(cfg.Items.TierPriceMultBP[item.Tier]) / 10000.0
	base := int64(math.Round(p.Coef * math.Pow(power, p.Exponent) * tierMult))

	if discountBP > 0 {
		if maxD := MaxDiscountBP(cfg); discountBP > maxD {
			discountBP = maxD
		}
		base = base * (10000 - discountBP) / 10000
	}
	if base < 1 {
		return 1
	}
	return base
}

// MaxDiscountBP is the hard ceiling on any shop discount, derived from the sell
// ratio rather than picked.
//
// The economy depends on every buy-then-sell round trip losing money. Sell pays
// back SellRatioBP of the full price, so a discount of (10000 - SellRatioBP)
// would make buying and selling break even, and anything beyond it would print
// gold. Capping at (10000 - 2*SellRatioBP) guarantees the buy price stays at
// least twice the sell price, leaving room for integer rounding at the low end.
//
// Deriving it means a designer who retunes SellRatioBP in the admin panel cannot
// accidentally open the loop.
func MaxDiscountBP(cfg *gameconfig.Bundle) int64 {
	d := 10000 - 2*cfg.Items.Price.SellRatioBP
	if d < 0 {
		return 0
	}
	return d
}

// SellPrice is what the player gets back.
//
// Deliberately computed from the UNDISCOUNTED buy price. If a shop discount fed
// into the sell price too, a maxed discount plus a sell would approach a
// break-even loop; excluding it keeps every round trip a guaranteed loss and
// makes arbitrage impossible by construction rather than by tuning.
func SellPrice(cfg *gameconfig.Bundle, item Instance) int64 {
	full := BuyPrice(cfg, item, 0)
	v := full * cfg.Items.Price.SellRatioBP / 10000
	if v < 1 {
		return 1
	}
	return v
}

