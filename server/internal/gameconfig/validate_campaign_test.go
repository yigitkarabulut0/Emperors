package gameconfig

import (
	"strings"
	"testing"
)

// The campaign's two load-bearing refusals.
//
// A validator that cannot be made to fire reads as cover, so each of these puts
// the mistake it exists for INTO the shipped document and watches Validate say
// no.

func TestValidateRejectsAGarrisonWhoseMightIsNotItsOwn(t *testing.T) {
	b, _ := LoadSeed()
	// The tiers.json mistake again, in a new file: a recorded number that drifts
	// away from the arithmetic the game fights with. One off is enough.
	s := &b.Campaign.Chapters[3].Stages[7]
	s.Might++
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a stage whose recorded Might is not what the game works out")
	}
	if !strings.Contains(err.Error(), "the game works it out at") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsACampaignAStageCouldBeFarmed(t *testing.T) {
	b, _ := LoadSeed()
	// Three times the stage's energy in wages, half of it on a repeat: a lord
	// would stop working and walk the same mile all evening.
	b.Campaign.RepeatBP = 5000
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a repeat that pays 1.5x what the same energy collects")
	}
	if !strings.Contains(err.Error(), "farming a stage would beat working") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// And the Might the validator recomputes must be the Might the game's own army
// package would say. The two are held together in game/army's tests; here we
// only prove the mirror is wired to the real numbers -- change the soldier
// table and every recorded Might in the campaign goes wrong at once.
func TestTheRecordedMightFollowsTheSoldierTable(t *testing.T) {
	b, _ := LoadSeed()
	for i := range b.Soldiers.Types {
		b.Soldiers.Types[i].Attack += 3
	}
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	if err := b.Validate(); err == nil {
		t.Fatal("stronger soldiers left every written-down garrison's Might unchanged")
	}
}

func TestValidateRejectsAnUnhorsedGarrison(t *testing.T) {
	b, _ := LoadSeed()
	// Speed is no part of Might, so a captain could be written down without it
	// and every recorded number would still agree -- while the stage played a
	// quarter easier than it claimed.
	b.Campaign.Chapters[0].Stages[0].Enemy.Speed = 0
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a garrison with no speed at all")
	}
	if !strings.Contains(err.Error(), "has no speed") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}
