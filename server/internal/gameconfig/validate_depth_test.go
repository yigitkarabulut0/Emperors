package gameconfig

import (
	"strings"
	"testing"
)

// The three refusals the hunt, the forge and the talents rest on.

func TestValidateRejectsAnExpeditionThatBeatsPlaying(t *testing.T) {
	b, _ := LoadSeed()
	// The furthest field, paying like a job: an hour away worth more than an
	// hour of the pool refilling. The tap that says "come back tomorrow" must
	// never be the best tap on the screen.
	f := &b.Hunt.Fields[len(b.Hunt.Fields)-1]
	f.GoldWages = f.Hours * b.regenEnergyPerHour()
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted an expedition that pays a full day's energy for waiting")
	}
	if !strings.Contains(err.Error(), "may not be half a day's play") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAForgeWhoseFeeIsUnderTheSellPrice(t *testing.T) {
	b, _ := LoadSeed()
	// A kinder fee, the shape of change that gets made to "help new players":
	// under what the forged piece sells for, and the anvil pays for itself.
	b.Forge.FeeBPOfNextPrice = b.Items.Price.SellRatioBP - 500
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a forge fee under what the piece it makes sells for")
	}
	if !strings.Contains(err.Error(), "the fee must be the larger share") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAForgeThatPrintsGold(t *testing.T) {
	b, _ := LoadSeed()
	// Two pieces instead of three and no fee at all: the round trip has to be
	// checked against the price curve itself, rung by rung.
	b.Forge.Pieces = 2
	b.Forge.FeeBPOfNextPrice = 0
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a forge whose round trip pays more than it costs")
	}
	if !strings.Contains(err.Error(), "the forge would print gold") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsATalentThatInventsAChannel(t *testing.T) {
	b, _ := LoadSeed()
	// A talent feeding a name nothing applies would be a second place a
	// percentage is worked out -- the one thing the bucket rule forbids.
	b.Talents.Branches[0].Talents[0].Bucket = "raid_take_bp"
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a talent feeding a channel the game does not have")
	}
	if !strings.Contains(err.Error(), "not a channel the game already has") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsATreeThatBreaksTheTaxCeiling(t *testing.T) {
	b, _ := LoadSeed()
	// Tax is a stored rate: it never passes through ApplyBucket, so nothing at
	// a call site would clamp what the tree adds to it.
	x := &b.Talents.Branches[0].Talents[0]
	x.Bucket = BucketTaxIncome
	x.PerRank = MaxTaxIncomeBP
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a tree that takes the tax rate past its ceiling")
	}
	if !strings.Contains(err.Error(), "the tax bucket reaches") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsATreeALordCouldFill(t *testing.T) {
	b, _ := LoadSeed()
	// A point every level, from the first: by the cap a lord has more points
	// than the tree has ranks, and the three branches stop being a choice.
	b.Talents.FirstLevel = 1
	b.Talents.LevelsPerPoint = 1
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a tree a lord is given enough points to fill")
	}
	if !strings.Contains(err.Error(), "a tree you can fill") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}
