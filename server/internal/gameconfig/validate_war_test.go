package gameconfig

import (
	"strings"
	"testing"
)

// The refusals the kingdom's boss and its wars rest on. Each puts the mistake
// it exists for INTO the shipped document and watches Validate say no.

func TestValidateRejectsABeastNobodyCouldKill(t *testing.T) {
	b, _ := LoadSeed()
	// The share is the whole calibration, and the shape of mistake here is a
	// zero added to it: a wall no kingdom could bring down in two days.
	b.Boss.HPPerMightBP *= 100
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a beast a hundred times too strong")
	}
	if !strings.Contains(err.Error(), "hp_per_might_bp") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsABeastThatKillsInOneSwing(t *testing.T) {
	b, _ := LoadSeed()
	// A beast's attack is a share of an AVERAGE member's Might. Reading it as a
	// share of the kingdom's whole muster -- which is what the first draft of
	// this document did -- makes every blow a death.
	b.Boss.Rotation[0].AttackBP = 11000
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a beast that swings for the whole muster")
	}
	if !strings.Contains(err.Error(), "would fall before the blow") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsABlowThatIsAWholeBattle(t *testing.T) {
	b, _ := LoadSeed()
	b.Boss.RoundsPerHit = b.Soldiers.Combat.MaxRounds
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a blow that is a whole battle")
	}
	if !strings.Contains(err.Error(), "fight CUT SHORT") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAWarWhereSittingStillWins(t *testing.T) {
	b, _ := LoadSeed()
	// The rule the whole war rests on: attacking must beat being attacked, or
	// the best kingdom is the one that never leaves its walls.
	b.War.Points.Held = b.War.Points.WinBase * b.War.Points.RatioMin / 10000
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a war a kingdom wins by sitting still")
	}
	if !strings.Contains(err.Error(), "never attacks does best") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsARoutedLordWorthFarming(t *testing.T) {
	b, _ := LoadSeed()
	b.War.RoutBP = 10000
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a routed lord worth as much as a standing one")
	}
	if !strings.Contains(err.Error(), "rout_bp") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAWarWorthLosing(t *testing.T) {
	b, _ := LoadSeed()
	b.War.Lost.Reputation = b.War.Won.Reputation
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a war worth as much lost as won")
	}
	if !strings.Contains(err.Error(), "as much to a kingdom as winning") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// And the titles the wave gives away have to exist, or the grant that names one
// is refused at the moment a lord earns it -- which is the worst moment.
func TestTheWaveSTitlesAreInTheCatalogue(t *testing.T) {
	b, _ := LoadSeed()
	for _, id := range []string{b.Boss.TopTitle, b.War.WarlordTitle} {
		if id == "" {
			t.Fatal("the wave gives a title with no id")
		}
		if b.Cosmetic(id) == nil {
			t.Fatalf("%s is given away and is not in cosmetics.json", id)
		}
	}
}

// A `section` that names a gate nobody wrote used to pass every check, because
// SectionLevel answers 1 for a section it has never heard of. Every document
// that carries one is held to HasSection now.
func TestValidateRejectsASectionNobodyWrote(t *testing.T) {
	for _, tc := range []struct {
		what string
		set  func(*Bundle)
	}{
		{"boss", func(b *Bundle) { b.Boss.Section = "no_such_gate" }},
		{"war", func(b *Bundle) { b.War.Section = "no_such_gate" }},
		{"campaign", func(b *Bundle) { b.Campaign.Section = "no_such_gate" }},
		{"hunt", func(b *Bundle) { b.Hunt.Section = "no_such_gate" }},
		{"forge", func(b *Bundle) { b.Forge.Section = "no_such_gate" }},
		{"talents", func(b *Bundle) { b.Talents.Section = "no_such_gate" }},
	} {
		b, _ := LoadSeed()
		tc.set(b)
		err := b.Validate()
		if err == nil {
			t.Fatalf("%s: Validate accepted a section nobody wrote", tc.what)
		}
		if !strings.Contains(err.Error(), "names no gate") {
			t.Errorf("%s: rejected for the wrong reason: %v", tc.what, err)
		}
	}
}
