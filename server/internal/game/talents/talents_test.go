package talents

import (
	"errors"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
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

// full is every rank in the tree, bought.
func full(c *gameconfig.Bundle) Spend {
	s := Spend{}
	for _, br := range c.Talents.Branches {
		for _, x := range br.Talents {
			s[x.ID] = x.Ranks
		}
	}
	return s
}

func TestPointsArriveWithLevelsAndLegacies(t *testing.T) {
	c := cfg(t)
	tc := c.Talents
	if got := Points(c, tc.FirstLevel-1, 0); got != 0 {
		t.Fatalf("a lord below the first level has %d points", got)
	}
	if got := Points(c, tc.FirstLevel, 0); got != 1 {
		t.Fatalf("the first point arrives as %d", got)
	}
	if got := Points(c, tc.FirstLevel+tc.LevelsPerPoint, 0); got != 2 {
		t.Fatalf("the second point arrives as %d", got)
	}
	if got := Points(c, tc.FirstLevel, 3); got != 1+3*tc.PointPerLegacy {
		t.Fatalf("three Legacies are worth %d", got-1)
	}
	// And the tree cannot be filled, which is the whole point of it.
	top := Points(c, int64(c.Progression.LevelCap), int64(c.Progression.Legacy.MaxStacks))
	if int(top) >= c.Talents.TotalRanks() {
		t.Fatalf("a lord at the cap with every Legacy has %d points for %d ranks",
			top, c.Talents.TotalRanks())
	}
}

func TestATierOpensOnItsOwnBranch(t *testing.T) {
	c := cfg(t)
	br := &c.Talents.Branches[0]
	// The deepest tier of the branch, and the gate it stands behind.
	deep := br.Talents[len(br.Talents)-1]
	gate := c.Talents.TierOpensAt(deep.Tier)
	if gate <= 0 {
		t.Fatal("the deepest tier has no gate at all")
	}
	s := Spend{}
	if Open(c, s, deep.ID) {
		t.Fatalf("%s is open with nothing spent in %s", deep.ID, br.ID)
	}
	err := CanBuy(c, s, 60, 0, deep.ID)
	if !errors.Is(err, ErrShut) {
		t.Fatalf("buying past a shut gate said %v", err)
	}
	// Pay the gate in the SAME branch, one rank at a time.
	spent := 0
	for _, x := range br.Talents {
		for r := 0; r < x.Ranks && spent < gate; r++ {
			s[x.ID]++
			spent++
		}
	}
	if !Open(c, s, deep.ID) {
		t.Fatalf("%s stayed shut with %d points in %s", deep.ID, gate, br.ID)
	}
	// Points in ANOTHER branch open nothing here.
	other := Spend{}
	for _, x := range c.Talents.Branches[1].Talents {
		other[x.ID] = x.Ranks
	}
	if Open(c, other, deep.ID) {
		t.Fatalf("%s opened on points spent in another branch", deep.ID)
	}
}

func TestWhatALordMayBuy(t *testing.T) {
	c := cfg(t)
	first := c.Talents.Branches[0].Talents[0]
	if err := CanBuy(c, Spend{}, c.Talents.FirstLevel, 0, first.ID); err != nil {
		t.Fatalf("a lord with their first point may not buy the first rank: %v", err)
	}
	if err := CanBuy(c, Spend{}, c.Talents.FirstLevel-1, 0, first.ID); !errors.Is(err, ErrNoPoints) {
		t.Fatalf("a lord with no points bought a rank: %v", err)
	}
	if err := CanBuy(c, Spend{first.ID: first.Ranks}, 60, 0, first.ID); !errors.Is(err, ErrMaxRanks) {
		t.Fatalf("a maxed talent took another rank: %v", err)
	}
	if err := CanBuy(c, Spend{}, 60, 0, "no_such_talent"); !errors.Is(err, ErrUnknown) {
		t.Fatalf("an invented talent was bought: %v", err)
	}
	// A tree that shrank under a lord reads as nothing left, never as debt.
	if got := Left(c, full(c), 60, 0); got != 0 {
		t.Fatalf("a lord who spent more than they were given has %d left", got)
	}
}

func TestRespecDoublesToItsCeiling(t *testing.T) {
	c := cfg(t)
	r := c.Talents.Respec
	if got := RespecCost(c, 0); got != r.BaseGold {
		t.Fatalf("the first respec costs %d", got)
	}
	if got := RespecCost(c, 1); got != r.BaseGold*r.StepBP/10000 {
		t.Fatalf("the second respec costs %d", got)
	}
	last := int64(0)
	for i := int64(0); i < 20; i++ {
		got := RespecCost(c, i)
		if got < last {
			t.Fatalf("respec %d costs %d, under the one before it (%d)", i, got, last)
		}
		if got > r.MaxGold {
			t.Fatalf("respec %d costs %d, over the ceiling %d", i, got, r.MaxGold)
		}
		last = got
	}
	if RespecCost(c, 20) != r.MaxGold {
		t.Fatal("the twentieth respec is not at the ceiling")
	}
}

// The rule the whole wave is held to: a talent is another way to earn a
// percentage, never a second place one is applied.
func TestEveryRankLandsInThePermanentLane(t *testing.T) {
	c := cfg(t)
	var e estates.Effects
	Apply(c, &e, 60, nil, full(c))

	if lane, ok := economy.TempLane(economy.BucketCollectIncome); ok && e.Bonuses[lane] != 0 {
		t.Fatalf("the tree put %d bp in the timed collect lane", e.Bonuses[lane])
	}
	if lane, ok := economy.TempLane(economy.BucketXPGain); ok && e.Bonuses[lane] != 0 {
		t.Fatalf("the tree put %d bp in the timed xp lane", e.Bonuses[lane])
	}
	if e.Bonuses[economy.BucketCollectIncome] <= 0 || e.Bonuses[economy.BucketXPGain] <= 0 {
		t.Fatal("a full tree lifts neither income nor experience")
	}
	if e.SoldierAtkBP <= 0 || e.SoldierDefBP <= 0 || e.SoldierSpdBP <= 0 {
		t.Fatal("a full WAR and DEFENCE tree does nothing for the soldiers")
	}
	if e.MaxEnergyFlat <= 0 || e.Bonuses[economy.BucketEnergyRegen] <= 0 {
		t.Fatal("a full DEFENCE tree does nothing for the pool")
	}
	if e.ShopDiscount <= 0 || e.LuckBP <= 0 || e.StealCapBP <= 0 || e.RansomBP <= 0 {
		t.Fatal("the tree's market, fortune and raiding ranks do nothing")
	}
}

// The storehouse's minutes are estates' own number, not a bucket, so they are
// the one channel that could have been added twice or not at all.
func TestTheStorehouseKeepsItsMinutes(t *testing.T) {
	c := cfg(t)
	base := estates.Derive(c, 60, nil, nil)
	with := estates.Derive(c, 60, nil, nil)
	Apply(c, &with, 60, nil, full(c))

	var minutes int64
	for _, br := range c.Talents.Branches {
		for _, x := range br.Talents {
			if x.Bucket == gameconfig.BucketStorehouseMinutes {
				minutes += x.PerRank * int64(x.Ranks)
			}
		}
	}
	if minutes == 0 {
		t.Skip("no talent lengthens the storehouse")
	}
	if got := with.OfflineCapSeconds - base.OfflineCapSeconds; got != minutes*60 {
		t.Fatalf("a full tree lengthened the storehouse by %d seconds and its ranks are %d minutes",
			got, minutes)
	}
}

// Tax is a stored RATE: it never passes through ApplyBucket, so nothing at a
// call site would clamp what the tree adds to it. It has to be recomputed from
// the sum, exactly as a kingdom's Royal Treasury is.
func TestTaxIsRecomputedFromTheSumAndStaysUnderItsCeiling(t *testing.T) {
	c := cfg(t)
	ups := map[string]int{}
	for _, u := range c.Estates.Upgrades {
		ups[u.ID] = u.MaxLevel
	}
	holds := map[string]int{}
	for _, h := range c.Estates.Holdings {
		holds[h.ID] = h.MaxLevel
	}
	kings := map[string]int{}
	for _, u := range c.Kingdoms.Upgrades {
		kings[u.ID] = u.MaxLevel
	}
	e := estates.Derive(c, 60, ups, holds)
	estates.ApplyKingdom(c, &e, 60, kings, holds)
	before := e.TaxMilliPerHour
	Apply(c, &e, 60, holds, full(c))

	if e.TaxIncomeBP > gameconfig.MaxTaxIncomeBP {
		t.Fatalf("everything at once reaches %d bp of tax and the ceiling is %d",
			e.TaxIncomeBP, gameconfig.MaxTaxIncomeBP)
	}
	if e.TaxMilliPerHour <= before {
		t.Fatalf("the tree's tithe changed the rate from %d to %d", before, e.TaxMilliPerHour)
	}
	// And the rate is the one TaxRate works out from the sum -- not the finished
	// rate multiplied a second time.
	if want := estates.TaxRate(c, 60, holds, e.TaxIncomeBP); e.TaxMilliPerHour != want {
		t.Fatalf("the rate is %d and the sum says %d: something multiplied twice",
			e.TaxMilliPerHour, want)
	}
}
