package boss

import (
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The wall is the kingdom's own, and it hardens.
func TestTheWallIsTheKingdomsOwn(t *testing.T) {
	c := cfg(t)
	small := HP(c, 10_000, 1)
	big := HP(c, 40_000, 1)
	if big != small*4 {
		t.Fatalf("four times the muster faces %d and one faces %d: the wall is not the kingdom's own",
			big, small)
	}
	if HP(c, 0, 1) != 0 {
		t.Fatal("a kingdom of nobody faces a wall")
	}
	last := int64(0)
	for level := 1; level <= 6; level++ {
		hp := HP(c, 10_000, level)
		if hp <= last {
			t.Fatalf("level %d is %d, no more than the level before it (%d)", level, hp, last)
		}
		last = hp
	}
}

// A blow never takes more than is left, and never gives the beast health back.
func TestABlowNeverTakesMoreThanIsLeft(t *testing.T) {
	c := cfg(t)
	mine, might := member(c, 30, "epic")
	for _, left := range []int64{1, 7, 500, 1_000_000} {
		rng := rand.New(rand.NewPCG(4, 4))
		_, dealt := Blow(c, rng, 11, mine, might, c.Boss.BossAt(0), might, left, 30)
		if dealt < 0 || dealt > left {
			t.Fatalf("with %d left a blow took %d", left, dealt)
		}
	}
}

// Valour is a share of an EQUAL share: in a kingdom where everybody fought,
// everybody is brave; where one fought alone, only they are.
func TestValourIsAShareOfAnEqualShare(t *testing.T) {
	c := cfg(t)
	need := Valour(c, 1000, 10)
	if want := 1000 / 10 * c.Boss.ValourShareBP / 10000; need != want {
		t.Fatalf("valour asks for %d, not %d", need, want)
	}
	if Valour(c, 0, 10) != 0 || Valour(c, 100, 0) != 0 {
		t.Fatal("valour asks for something of a cycle nobody fought")
	}
	// Ten lords who each did a tenth are all brave; one who did a hundredth is
	// not.
	e := Earns(c, 100, 1000, 10, false)
	if !e.Hit || !e.Valour || e.Kill {
		t.Fatalf("a lord who did an equal share earned %+v", e)
	}
	if Earns(c, 10, 1000, 10, false).Valour {
		t.Fatal("a lord who did a hundredth was counted brave")
	}
	if Earns(c, 0, 1000, 10, true).Hit {
		t.Fatal("a lord who never swung was counted")
	}
	if !Earns(c, 100, 1000, 10, true).Kill {
		t.Fatal("a lord who fought the cycle it fell was not counted a slayer")
	}
}

// A chest grows with the beast, and its DIAMONDS do not: a beast that paid a
// tenth more diamonds every time would be a diamond mine with a dragon on it.
func TestAChestGrowsButItsDiamondsDoNot(t *testing.T) {
	c := cfg(t)
	kill := c.Boss.Chest("slain")
	if kill == nil {
		t.Skip("no kill chest")
	}
	one := Chest(c, kill, 1)
	five := Chest(c, kill, 5)
	if five.GoldWages <= one.GoldWages || five.XPWages <= one.XPWages {
		t.Fatalf("level five pays %d/%d wages and level one %d/%d",
			five.GoldWages, five.XPWages, one.GoldWages, one.XPWages)
	}
	if five.Diamonds != one.Diamonds {
		t.Fatalf("level five pays %d diamonds and level one %d", five.Diamonds, one.Diamonds)
	}
	// And whatever it pays, it is a reward the game may pay at all.
	if bad := c.CheckReward(five, false); len(bad) > 0 {
		t.Fatalf("a level-five chest is not payable: %v", bad)
	}
}

// Every chest the balance writes asks for something a lord can do.
func TestEveryChestAsksForSomethingDoable(t *testing.T) {
	c := cfg(t)
	for _, chest := range c.Boss.Chests {
		e := Earned{Hit: true, Valour: true, Kill: true}
		if !e.Has(chest.Need) {
			t.Fatalf("%s asks for %q, which nothing grants", chest.ID, chest.Need)
		}
		if (Earned{}).Has(chest.Need) {
			t.Fatalf("%s is earned by a lord who did nothing", chest.ID)
		}
	}
	if (Earned{}).Has("no_such_need") {
		t.Fatal("an invented condition is met")
	}
}

// The beast's own numbers are shares of an AVERAGE member, so the fight is the
// same for every kingdom; only the wall changes.
func TestTheBeastIsScaledToOneLordAtATime(t *testing.T) {
	c := cfg(t)
	b := c.Boss.BossAt(0)
	small := Army(c, b, 1000, 10_000, 30)
	big := Army(c, b, 4000, 10_000, 30)
	if big.Units[0].Attack != small.Units[0].Attack*4 {
		t.Fatalf("a beast facing a four-times-stronger lord hits for %d against %d",
			big.Units[0].Attack, small.Units[0].Attack)
	}
	if small.Units[0].HP != 10_000 {
		t.Fatalf("the beast fights with %d health, not what is left of it", small.Units[0].HP)
	}
	if Army(c, nil, 1000, 1, 1).PlayerID != "" {
		t.Fatal("a beast that is not in the rotation still musters")
	}
}

// The rotation comes round, and never runs off the end.
func TestTheRotationComesRound(t *testing.T) {
	c := cfg(t)
	n := len(c.Boss.Rotation)
	for i := 0; i < n*3; i++ {
		b := c.Boss.BossAt(i)
		if b == nil || b.ID != c.Boss.Rotation[i%n].ID {
			t.Fatalf("cycle %d drew %v", i, b)
		}
	}
	if c.Boss.BossAt(-1) == nil {
		t.Fatal("a cycle before the first drew nothing")
	}
	if c.Boss.Boss("no_such_beast") != nil {
		t.Fatal("a beast nobody painted is in the rotation")
	}
}

// A blow costs what a raid costs, and never nothing.
func TestABlowCostsEnergy(t *testing.T) {
	c := cfg(t)
	last := int64(0)
	for _, level := range []int64{1, 10, 30, 60} {
		cost := EnergyCost(c, level)
		if cost < last {
			t.Fatalf("level %d pays %d, under level %d", level, cost, last)
		}
		if cost <= 0 {
			t.Fatalf("a blow at level %d costs nothing", level)
		}
		last = cost
	}
}

var _ = gameconfig.BossNeedKill
