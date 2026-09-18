package gameconfig

import (
	"strings"
	"testing"
)

// The refusals Herald's Tidings rests on. Each puts the mistake it exists for
// INTO the shipped document and watches Validate say no.
//
// The one that matters is the first: an advert is MONEY. The lord pays with
// their attention and the house is paid by the advertiser, so an advert that
// handed back gold would be gold bought with money by another name -- which is
// the one rule the whole game is built around.

func TestValidateRejectsAnAdvertThatPaysGold(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.Grant.Gold = 5000
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted an advert that pays gold")
	}
	if !strings.Contains(err.Error(), "may not carry gold") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAnAdvertThatPaysExperience(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.Grant.XPWages = 40
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted an advert that pays experience")
	}
	if !strings.Contains(err.Error(), "may not carry experience") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAnAdvertThatPaysGear(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.Grant.Items = []ItemGrant{{Tier: "rare", Count: 1}}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted an advert that pays gear")
	}
	if !strings.Contains(err.Error(), "may not carry gear") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAHeraldWithNoLimit(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.PerDay = 500
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted five hundred adverts a day")
	}
	if !strings.Contains(err.Error(), "per_day") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAHeraldThatPaysNothing(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.Grant = RewardBundle{}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted an advert that pays nothing")
	}
	if !strings.Contains(err.Error(), "pays nothing") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsATicketThatNeverDies(t *testing.T) {
	b, _ := LoadSeed()
	b.Commerce.Ads.TicketMinutes = 60 * 24
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a watch that may come back a day later")
	}
	if !strings.Contains(err.Error(), "ticket_minutes") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// And the shipped document is one the rules accept.
func TestTheShippedHeraldIsWithinItsOwnRules(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	if problems := b.validateAds(); len(problems) > 0 {
		t.Fatalf("the shipped herald is refused: %v", problems)
	}
	a := b.Commerce.Ads
	if a.Grant.Diamonds <= 0 {
		t.Error("the herald pays no diamonds, and diamonds are the only thing an advert may pay")
	}
	// What a lord may take from it in a day, said out loud so a change to
	// either number has to be meant.
	if day := a.Grant.Diamonds * int64(a.PerDay); day > 12 {
		t.Errorf("the herald pays %d diamonds a day, over the calendar's own twelve", day)
	}
}
