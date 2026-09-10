package service

import (
	"math"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// A reroll costs exactly what the manual loop costs -- dismiss for the refund,
// recruit again -- for every type at every level. Cheaper and the refund is an
// arbitrage; dearer and nobody presses the button.
func TestRerollCostsWhatTheManualLoopCosts(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	for i := range b.Soldiers.Types {
		st := &b.Soldiers.Types[i]
		for level := int64(1); level <= int64(b.Progression.LevelCap); level++ {
			price := soldierRerollCost(b, st, level)
			loop := recruitCost(b, st, level) - dismissRefund(b, st, level)
			if price != loop {
				t.Fatalf("%s at %d: reroll %d, dismiss-and-recruit %d", st.ID, level, price, loop)
			}
			if price <= 0 {
				t.Fatalf("%s at %d: a reroll costs %d", st.ID, level, price)
			}
			if price <= dismissRefund(b, st, level) {
				t.Fatalf("%s at %d: a reroll (%d) costs no more than the refund (%d)",
					st.ID, level, price, dismissRefund(b, st, level))
			}
		}
	}
}

// The reroll draws from the recruit's own table, so the published odds are its
// odds. Checked the way a player would: roll it many times and count.
func TestRerollDrawMatchesThePublishedOdds(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	secret := []byte("test-secret")
	player, soldier := uuid.New(), uuid.New()
	st := b.SoldierType("gladiator")
	if st == nil {
		t.Fatal("no gladiator in the seed")
	}
	const level, n = 30, 40000
	luck := items.EffectiveLuckCoef(st.LuckCoef, 0)
	odds := items.TierOdds(b, st.Weights, luck, level)

	counts := map[string]int{}
	for seq := uint64(1); seq <= n; seq++ {
		rng := game.SeedForString(secret, player.String()+":"+soldier.String(), seq, 3, 0x2E2011)
		counts[items.RollTier(b, rng, st.Weights, luck, level)]++
	}
	for _, o := range odds {
		want := float64(o.BP) / 10000
		got := float64(counts[o.Tier]) / n
		// Four standard errors: a real mismatch is far outside it, noise is not.
		se := math.Sqrt(want*(1-want)/n) * 4
		if math.Abs(got-want) > se+0.002 {
			t.Errorf("%s: drawn %.4f of the time, published %.4f", o.Tier, got, want)
		}
	}

	// Different sequence numbers draw differently; the same one draws the same.
	first := items.RollTier(b, game.SeedForString(secret, "a:b", 7, 1, 0x2E2011), st.Weights, luck, level)
	again := items.RollTier(b, game.SeedForString(secret, "a:b", 7, 1, 0x2E2011), st.Weights, luck, level)
	if first != again {
		t.Error("the same request drew two different tiers, so a retry could reroll for free")
	}
}
