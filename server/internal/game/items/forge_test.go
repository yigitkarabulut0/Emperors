package items

import (
	"errors"
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func forgePieces(c *gameconfig.Bundle, slot, tier string, ilvls ...int64) []Instance {
	var out []Instance
	for _, l := range ilvls {
		atk, def, spd := Stat(c, slot, tier, l, 100, false)
		out = append(out, Instance{DefID: "x", Slot: slot, Tier: tier, Ilvl: l,
			QualityPct: 100, Attack: atk, Defense: def, Speed: spd})
	}
	return out
}

func TestTheForgeTakesThreeOfOneKind(t *testing.T) {
	c := cfg(t)
	n := c.Forge.Pieces
	ok := forgePieces(c, "weapon", "common", 10, 12, 14)
	if err := CanForge(c, ok[:n]); err != nil {
		t.Fatalf("three commons were refused: %v", err)
	}
	if err := CanForge(c, ok[:n-1]); !errors.Is(err, ErrForgeCount) {
		t.Fatalf("two pieces were taken: %v", err)
	}
	mixed := forgePieces(c, "weapon", "common", 10, 12)
	mixed = append(mixed, forgePieces(c, "armor", "common", 14)...)
	if err := CanForge(c, mixed); !errors.Is(err, ErrForgeMixed) {
		t.Fatalf("a sword, a sword and a breastplate were taken: %v", err)
	}
	top := c.TierIDsAscending()[len(c.TierIDsAscending())-1]
	if err := CanForge(c, forgePieces(c, "weapon", top, 10, 12, 14)); !errors.Is(err, ErrForgeTier) {
		t.Fatalf("the top of the ladder was forged into something: %v", err)
	}
}

func TestWhatComesOutOfTheForge(t *testing.T) {
	c := cfg(t)
	pieces := forgePieces(c, "weapon", "rare", 20, 31, 27)
	got, err := Forge(c, rand.New(rand.NewPCG(1, 2)), pieces, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got.Tier != NextTier(c, "rare") {
		t.Fatalf("three rares made a %s", got.Tier)
	}
	if got.Slot != "weapon" {
		t.Fatalf("three swords made a %s", got.Slot)
	}
	if got.Ilvl != 31 {
		t.Fatalf("the piece came out at mark %d and the best of the three was 31", got.Ilvl)
	}
	if got.QualityPct < c.Forge.Quality.MinPct || got.QualityPct > c.Forge.Quality.MaxPct {
		t.Fatalf("quality %d is outside the band the screen published", got.QualityPct)
	}
	if got.Attack <= 0 {
		t.Fatal("the forged piece has no attack")
	}
}

// The rule the forge lives under: three pieces in, one out, and the whole round
// trip loses money. gameconfig.Validate proves it from the two ratios; this
// proves it on real pieces, at every rung and in every slot.
func TestForgingAndSellingIsAlwaysALoss(t *testing.T) {
	c := cfg(t)
	for _, tier := range c.Forge.Tiers {
		for _, slot := range []string{"weapon", "armor", "horse"} {
			for _, ilvl := range []int64{1, 20, 40, 60} {
				pieces := forgePieces(c, slot, tier, ilvl, ilvl, ilvl)
				fee := ForgeFee(c, slot, tier, ilvl)
				spent := fee
				for _, p := range pieces {
					spent += SellPrice(c, p) // what feeding it in costs you
				}
				// The best piece the forge could possibly produce.
				best := forgeBest(c, slot, NextTier(c, tier), ilvl)
				if got := SellPrice(c, best); got >= spent {
					t.Fatalf("%s %s at mark %d: forging and selling pays %d for %d spent",
						tier, slot, ilvl, got, spent)
				}
			}
		}
	}
}

// forgeBest is the luckiest piece the anvil could hand back: the top of its
// quality band and a masterwork.
func forgeBest(c *gameconfig.Bundle, slot, tier string, ilvl int64) Instance {
	atk, def, spd := Stat(c, slot, tier, ilvl, c.Forge.Quality.MaxPct, true)
	return Instance{Slot: slot, Tier: tier, Ilvl: ilvl, QualityPct: c.Forge.Quality.MaxPct,
		Masterwork: true, Attack: atk, Defense: def, Speed: spd}
}

// And forging has to be worth doing, or the anvil is a wall with an animation:
// three spare pieces and the fee must come to less than simply buying one.
func TestForgingBeatsBuyingTheSamePiece(t *testing.T) {
	c := cfg(t)
	for _, tier := range c.Forge.Tiers {
		for _, slot := range []string{"weapon", "armor", "horse"} {
			ilvl := int64(30)
			pieces := forgePieces(c, slot, tier, ilvl, ilvl, ilvl)
			spent := ForgeFee(c, slot, tier, ilvl)
			for _, p := range pieces {
				spent += SellPrice(c, p)
			}
			buy := forgePrice(c, slot, NextTier(c, tier), ilvl)
			if spent >= buy {
				t.Fatalf("%s %s: forging costs %d and the shop asks %d -- nobody would forge",
					tier, slot, spent, buy)
			}
		}
	}
}

func TestTheFeeFollowsTheRankAbove(t *testing.T) {
	c := cfg(t)
	last := int64(0)
	for _, tier := range c.Forge.Tiers {
		fee := ForgeFee(c, "weapon", tier, 30)
		if fee <= last {
			t.Fatalf("forging a %s costs %d, after %d: a better rank must cost more", tier, fee, last)
		}
		last = fee
	}
	top := c.TierIDsAscending()[len(c.TierIDsAscending())-1]
	if got := ForgeFee(c, "weapon", top, 30); got != 0 {
		t.Fatalf("the top of the ladder asks %d to forge into nothing", got)
	}
}
