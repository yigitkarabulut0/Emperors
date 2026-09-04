package gameconfig

import "testing"

func TestSeedLoadsAndValidates(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatalf("seed must load and validate: %v", err)
	}
	if got := len(b.Jobs.Jobs); got != 15 {
		t.Errorf("jobs = %d, want 15", got)
	}
	if b.Progression.LevelCap != 60 {
		t.Errorf("level cap = %d, want 60", b.Progression.LevelCap)
	}
	if got := len(b.Tiers.Tiers); got != 7 {
		t.Errorf("tiers = %d, want 7", got)
	}
}

func TestJobsForLevelGatesCorrectly(t *testing.T) {
	b, _ := LoadSeed()
	// A brand new player must have exactly one thing to do — the tutorial
	// depends on there being no choice to make.
	if got := len(b.JobsForLevel(1)); got != 1 {
		t.Errorf("level 1 jobs = %d, want 1", got)
	}
	if got := len(b.JobsForLevel(60)); got != 15 {
		t.Errorf("level 60 jobs = %d, want all 15", got)
	}
	if got := len(b.JobsForLevel(0)); got != 0 {
		t.Errorf("level 0 jobs = %d, want 0", got)
	}
}

func TestMilestoneBonusesReplaceRatherThanStack(t *testing.T) {
	b, _ := LoadSeed()
	cases := []struct{ collects, wantBP int64 }{
		{0, 0}, {24, 0},
		{25, 500}, {49, 500},
		{50, 1000}, {99, 1000},
		{100, 1500},
		{250, 2000},
		{500, 2500},
		{1000, 3000},
		{999999, 3000}, // hard cap: the bucket must stay inside its ceiling
	}
	for _, c := range cases {
		if got := b.MilestoneBonusBP(c.collects); got != c.wantBP {
			t.Errorf("MilestoneBonusBP(%d) = %d, want %d", c.collects, got, c.wantBP)
		}
	}
}

func TestGoldPerEnergyNeverDecreases(t *testing.T) {
	// This is the property that makes the ladder meaningful: unlocking a job must
	// never be a downgrade. Validate() enforces it; this proves the shipped data
	// actually satisfies it.
	b, _ := LoadSeed()
	var prev float64
	for _, j := range b.jobsAsc {
		gpe := float64(j.BaseGold) / float64(j.EnergyCost)
		if gpe < prev {
			t.Errorf("job %q gold/energy %.2f < previous %.2f", j.ID, gpe, prev)
		}
		prev = gpe
	}
	// And it should actually rise meaningfully, or the ladder is pointless.
	first := float64(b.jobsAsc[0].BaseGold) / float64(b.jobsAsc[0].EnergyCost)
	if prev/first < 10 {
		t.Errorf("gold/energy only rises %.1fx across the ladder, want >=10x", prev/first)
	}
}

func TestValidateCatchesADowngradeJob(t *testing.T) {
	b, _ := LoadSeed()
	// Make the last job strictly worse than the one before it.
	b.Jobs.Jobs[len(b.Jobs.Jobs)-1].BaseGold = 1
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	if err := b.Validate(); err == nil {
		t.Fatal("Validate accepted a job that is a downgrade to unlock")
	}
}
