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
