// Package hunt is the pure half of the expeditions: what a soldier sent out
// brings back, and when.
//
// The only income in the game that costs no energy at all, so what it costs
// instead is the SOLDIER. Away, they do not fight, cannot be rerolled, dismissed
// or re-geared, and the army's Might on every table is the Might of who is left
// standing in the yard.
//
// Pure like the rest of internal/game: time arrives as a parameter and the roll
// arrives as a seeded generator.
package hunt

import (
	"math/rand/v2"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Haul is what a soldier comes home with, rolled once at DISPATCH and frozen.
//
// Rolled at dispatch and not at return, because a reward rolled on the way home
// would be a reward worth waiting on a clock for -- and because a lord who was
// shown a range before the tap is owed a number that was decided by the tap.
type Haul struct {
	GoldWages int64 `json:"gold_wages"`
	XPWages   int64 `json:"xp_wages"`
	// The rank of the piece of gear that was found, or empty for none. The item
	// itself is rolled when it is handed over, by the same roller every other
	// piece of gear in the game comes out of.
	ItemTier string `json:"item_tier,omitempty"`
}

// Empty reports a haul worth nothing at all.
func (h Haul) Empty() bool { return h.GoldWages <= 0 && h.XPWages <= 0 && h.ItemTier == "" }

// Bundle is the haul as the one thing a reward is paid from.
func (h Haul) Bundle() gameconfig.RewardBundle {
	b := gameconfig.RewardBundle{GoldWages: h.GoldWages, XPWages: h.XPWages}
	if h.ItemTier != "" {
		b.Items = []gameconfig.ItemGrant{{Tier: h.ItemTier, Count: 1}}
	}
	return b
}

// Ends is when a soldier sent to a field comes home.
func Ends(f *gameconfig.HuntField, start time.Time) time.Time {
	if f == nil {
		return start
	}
	return start.Add(time.Duration(f.Hours) * time.Hour)
}

// RankBP is what a soldier's rank is worth on the road, in basis points.
//
// A share of the tier ladder's own multiplier, so a mystic scout is worth about
// two and a half of a common one rather than five: the road is a place for the
// soldiers you are not fighting with, and it should not become the best thing to
// do with your best.
func RankBP(cfg *gameconfig.Bundle, tier string) int64 {
	mult := cfg.Items.TierMultBP[tier]
	if mult <= 10000 {
		return 10000
	}
	return 10000 + (mult-10000)*cfg.Hunt.TierShareBP/10000
}

// Roll is what this soldier brings back from this field.
//
// The wages are the field's own figure at the soldier's rank, moved by a roll
// inside the spread the card showed. The piece of gear is a separate draw, so a
// poor haul can still come home with something.
func Roll(cfg *gameconfig.Bundle, rng *rand.Rand, f *gameconfig.HuntField, tier string) Haul {
	if f == nil {
		return Haul{}
	}
	rank := RankBP(cfg, tier)
	spread := cfg.Hunt.SpreadBP
	// One roll for the pair, so a good expedition is good at both: two draws
	// would average out to the middle and the spread would stop being felt.
	roll := int64(0)
	if spread > 0 {
		roll = rng.Int64N(2*spread+1) - spread
	}
	scale := func(v int64) int64 {
		if v <= 0 {
			return 0
		}
		out := v * rank / 10000 * (10000 + roll) / 10000
		if out < 1 {
			out = 1
		}
		return out
	}
	h := Haul{GoldWages: scale(f.GoldWages), XPWages: scale(f.XPWages)}
	if f.ItemChanceBP > 0 && rng.Int64N(10000) < f.ItemChanceBP {
		h.ItemTier = f.ItemTier
	}
	return h
}

// Range is what the card promises before the tap: the least and the most this
// soldier could bring back from this field. Nothing is ever paid outside it.
func Range(cfg *gameconfig.Bundle, f *gameconfig.HuntField, tier string) (low, high Haul) {
	if f == nil {
		return Haul{}, Haul{}
	}
	rank := RankBP(cfg, tier)
	edge := func(v, rollBP int64) int64 {
		if v <= 0 {
			return 0
		}
		out := v * rank / 10000 * (10000 + rollBP) / 10000
		if out < 1 {
			out = 1
		}
		return out
	}
	s := cfg.Hunt.SpreadBP
	low = Haul{GoldWages: edge(f.GoldWages, -s), XPWages: edge(f.XPWages, -s)}
	high = Haul{GoldWages: edge(f.GoldWages, s), XPWages: edge(f.XPWages, s)}
	return low, high
}
