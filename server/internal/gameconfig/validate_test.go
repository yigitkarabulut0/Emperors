package gameconfig

import (
	"strings"
	"testing"
)

// The two checks added when the level curve was rebalanced.
//
// A validator that cannot be made to fire is worse than none, because it reads
// as cover. Both of these reproduce the exact configuration that shipped.

func TestValidateRejectsAFlatXPLadder(t *testing.T) {
	b, _ := LoadSeed()
	// The formula that actually shipped: xp/energy rising 2.00 -> 2.60 across the
	// whole ladder, while the experience a level costs rises about 400x.
	for i := range b.Jobs.Jobs {
		j := &b.Jobs.Jobs[i]
		j.BaseXP = int64(float64(j.EnergyCost) * (1.40 + 0.02*float64(j.UnlockLevel)))
		if j.BaseXP < 2 {
			j.BaseXP = 2
		}
	}
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a ladder whose xp/energy rises 1.3x")
	}
	if !strings.Contains(err.Error(), "xp/energy only rises") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAPoolSmallerThanAnHourOfRegen(t *testing.T) {
	b, _ := LoadSeed()
	// Halving the regen period without growing the pool: the change that looks
	// like a buff and is worth nothing to anyone who checks in hourly.
	b.Progression.Energy.BaseMax = 60
	b.Progression.Energy.RegenBaseSeconds = 30
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a 60-point pool at two energy a minute")
	}
	if !strings.Contains(err.Error(), "less than one hour of regen") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// The store's prices are the one place a forgotten generator run turns into a
// free purchase rather than a refused load.
func TestValidateRejectsAFreeRename(t *testing.T) {
	b, _ := LoadSeed()
	b.Progression.Store.RenameDiamonds = 0
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a rename that costs nothing")
	}
	if !strings.Contains(err.Error(), "rename_diamonds") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// The two joining settings read as zero when the generator gained them and was
// not re-run -- the same failure that once shipped an action for one gold.
// Zero is not a setting for either: no cooldown makes a kingdom a raid shield,
// and a request cap of zero refuses every request.
func TestValidateRejectsMissingJoinSettings(t *testing.T) {
	for _, c := range []struct {
		field string
		zero  func(b *Bundle)
	}{
		{"rejoin_cooldown_minutes", func(b *Bundle) { b.Kingdoms.RejoinCooldownMinutes = 0 }},
		{"max_join_requests", func(b *Bundle) { b.Kingdoms.MaxJoinRequests = 0 }},
	} {
		b, _ := LoadSeed()
		c.zero(b)
		if err := b.build(); err != nil {
			t.Fatal(err)
		}
		err := b.Validate()
		if err == nil {
			t.Fatalf("Validate accepted a zero %s", c.field)
		}
		if !strings.Contains(err.Error(), c.field) {
			t.Errorf("%s: rejected for the wrong reason: %v", c.field, err)
		}
	}
}

// A reroll costs the recruit price less the dismiss refund, and both come off
// base_cost and sell_ratio_bp. Each of these would price it at nothing or roll
// it from an empty table.
func TestValidateRejectsAFreeOrEmptyRecruit(t *testing.T) {
	for _, c := range []struct {
		name   string
		break_ func(b *Bundle)
		want   string
	}{
		{"free soldier", func(b *Bundle) { b.Soldiers.Types[0].BaseCost = 0 }, "base_cost must be positive"},
		{"empty weights", func(b *Bundle) {
			for k := range b.Soldiers.Types[1].Weights {
				b.Soldiers.Types[1].Weights[k] = 0
			}
		}, "tier weights sum to nothing"},
		{"full refund", func(b *Bundle) { b.Items.Price.SellRatioBP = 10000 }, "reroll would cost nothing"},
	} {
		b, _ := LoadSeed()
		c.break_(b)
		if err := b.build(); err != nil {
			t.Fatal(err)
		}
		err := b.Validate()
		if err == nil {
			t.Fatalf("%s: Validate accepted it", c.name)
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: rejected for the wrong reason: %v", c.name, err)
		}
	}
}
