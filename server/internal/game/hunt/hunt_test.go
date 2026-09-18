package hunt

import (
	"math/rand/v2"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t testing.TB) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// What the card promised is what the road pays. A lord who was shown a range
// before the tap must never be handed a number outside it.
func TestNothingIsEverPaidOutsideTheRangeTheCardShowed(t *testing.T) {
	c := cfg(t)
	for i := range c.Hunt.Fields {
		f := &c.Hunt.Fields[i]
		for _, tier := range c.TierIDsAscending() {
			low, high := Range(c, f, tier)
			for seed := uint64(1); seed <= 500; seed++ {
				h := Roll(c, rand.New(rand.NewPCG(seed, 3)), f, tier)
				if h.GoldWages < low.GoldWages || h.GoldWages > high.GoldWages {
					t.Fatalf("%s/%s: paid %d gold wages, card said %d..%d",
						f.ID, tier, h.GoldWages, low.GoldWages, high.GoldWages)
				}
				if h.XPWages < low.XPWages || h.XPWages > high.XPWages {
					t.Fatalf("%s/%s: paid %d xp wages, card said %d..%d",
						f.ID, tier, h.XPWages, low.XPWages, high.XPWages)
				}
			}
		}
	}
}

// The rank matters, and it matters LESS than the ladder does elsewhere: the road
// is for the soldiers you are not fighting with.
func TestABetterSoldierBringsBackMoreButNotTheLadder(t *testing.T) {
	c := cfg(t)
	ids := c.TierIDsAscending()
	last := int64(0)
	for _, tier := range ids {
		bp := RankBP(c, tier)
		if bp <= last {
			t.Fatalf("%s is worth %d bp on the road, after %d", tier, bp, last)
		}
		last = bp
	}
	top := RankBP(c, ids[len(ids)-1])
	if top >= c.Items.TierMultBP[ids[len(ids)-1]] {
		t.Fatalf("the best soldier is worth %d bp on the road and %d in a fight: "+
			"the road must be flatter than the ladder", top, c.Items.TierMultBP[ids[len(ids)-1]])
	}
	if top > 40000 {
		t.Fatalf("the best soldier is worth %.1fx the plainest on the road", float64(top)/10000)
	}
}

// One roll for the pair: a good expedition is good at both, or the spread
// averages away and stops being felt.
func TestTheSpreadIsFelt(t *testing.T) {
	c := cfg(t)
	f := c.Hunt.Field(c.Hunt.Fields[len(c.Hunt.Fields)-1].ID)
	seen := map[int64]bool{}
	for seed := uint64(1); seed <= 200; seed++ {
		h := Roll(c, rand.New(rand.NewPCG(seed, 9)), f, "common")
		seen[h.GoldWages] = true
	}
	if len(seen) < 5 {
		t.Fatalf("two hundred expeditions to %s came back with %d different hauls", f.ID, len(seen))
	}
}

func TestASoldierComesHomeWhenTheFieldSays(t *testing.T) {
	c := cfg(t)
	start := time.Date(2026, 9, 17, 8, 0, 0, 0, time.UTC)
	for i := range c.Hunt.Fields {
		f := &c.Hunt.Fields[i]
		if got := Ends(f, start); !got.Equal(start.Add(time.Duration(f.Hours) * time.Hour)) {
			t.Fatalf("%s: home at %v", f.ID, got)
		}
	}
	if got := Ends(nil, start); !got.Equal(start) {
		t.Fatal("a soldier sent nowhere is away")
	}
}

func TestSlotsOpenWithLevel(t *testing.T) {
	c := cfg(t)
	if n := c.Hunt.SlotsAt(1); n != 0 {
		t.Fatalf("a lord of level 1 may send %d soldiers out", n)
	}
	last := 0
	for _, s := range c.Hunt.Slots {
		n := c.Hunt.SlotsAt(s.Level)
		if n <= last {
			t.Fatalf("at level %d a lord may send %d, after %d", s.Level, n, last)
		}
		last = n
	}
	top := c.Hunt.Slots[len(c.Hunt.Slots)-1]
	if n := c.Hunt.SlotsAt(top.Level + 100); n != top.Slots {
		t.Fatalf("past the last rung a lord may send %d, and the last rung is %d", n, top.Slots)
	}
}

// A haul is paid the one way a reward is ever paid.
func TestAHaulIsARewardBundle(t *testing.T) {
	c := cfg(t)
	h := Haul{GoldWages: 12, XPWages: 8, ItemTier: "rare"}
	b := h.Bundle()
	if b.GoldWages != 12 || b.XPWages != 8 {
		t.Fatalf("the bundle carries %d/%d wages", b.GoldWages, b.XPWages)
	}
	if len(b.Items) != 1 || b.Items[0].Tier != "rare" || b.Items[0].Count != 1 {
		t.Fatalf("the bundle carries %v", b.Items)
	}
	if bad := c.CheckReward(b, false); len(bad) > 0 {
		t.Fatalf("a haul is not a reward the game may pay: %v", bad)
	}
	if (Haul{}).Empty() != true {
		t.Fatal("an empty haul is not empty")
	}
}
