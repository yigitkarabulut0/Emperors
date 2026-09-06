package economy

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t *testing.T) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

var t0 = time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)

// ---------------------------------------------------------------- energy ----

func TestSettleFrequentPollingDoesNotLoseEnergy(t *testing.T) {
	// The property that justifies advancing the anchor by time CONSUMED rather
	// than to `now`. Integer division drops the sub-period remainder, so if the
	// anchor jumped to `now` on every call, a client that polls once a second
	// would regenerate strictly slower than one that polls once a minute — a
	// bug that only shows up as "my energy fills slower than my friend's".
	c := cfg(t)
	period := RegenPeriodMillis(c, Bonuses{})

	// Derived from the configured period rather than hardcoded, and the ceiling
	// is set above the answer, so this stays a test of Settle rather than a
	// second copy of the balance numbers that fails on every retune.
	const window = 59 * time.Minute
	want := int64(window/time.Millisecond) / period
	maxE := want * 2

	rare := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, maxE, period, t0.Add(window))

	frequent := EnergyState{Milli: 0, UpdatedAt: t0}
	for i := 1; i <= 59*60; i++ { // once a second for 59 minutes
		frequent = Settle(frequent, maxE, period, t0.Add(time.Duration(i)*time.Second))
	}

	if rare.Milli != frequent.Milli {
		t.Errorf("polling frequency changed the result: rare=%d frequent=%d (lost %d milli)",
			rare.Milli, frequent.Milli, rare.Milli-frequent.Milli)
	}
	if got := Whole(rare); got != want {
		t.Errorf("%v at one per %dms = %d energy, want %d", window, period, got, want)
	}
}

func TestSettleClampsAtMaxAndDoesNotBankOverflow(t *testing.T) {
	c := cfg(t)
	period := RegenPeriodMillis(c, Bonuses{})
	maxE := int64(60)

	// Away for 10 hours with a 60 bar: only 60 is kept, the rest is lost. That
	// loss is the design — it is what makes Max Energy worth buying.
	full := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, maxE, period, t0.Add(10*time.Hour))
	if got := Whole(full); got != 60 {
		t.Fatalf("energy = %d, want clamped to 60", got)
	}

	// Spending immediately must not instantly refund from banked overflow.
	spent, ok := Spend(full, 10)
	if !ok {
		t.Fatal("spend failed")
	}
	after := Settle(spent, maxE, period, t0.Add(10*time.Hour))
	if got := Whole(after); got != 50 {
		t.Errorf("after spending 10 at full, energy = %d, want 50 (no banked overflow)", got)
	}
}

func TestSettleSurvivesBackwardsClock(t *testing.T) {
	c := cfg(t)
	period := RegenPeriodMillis(c, Bonuses{})
	s := EnergyState{Milli: 30_000, UpdatedAt: t0}
	got := Settle(s, 60, period, t0.Add(-time.Hour))
	if got.Milli != 30_000 {
		t.Errorf("a backwards clock destroyed energy: %d, want 30000", got.Milli)
	}
}

func TestSettleIsIdempotent(t *testing.T) {
	c := cfg(t)
	period := RegenPeriodMillis(c, Bonuses{})
	now := t0.Add(90 * time.Second)
	a := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, 60, period, now)
	b := Settle(a, 60, period, now)
	if a != b {
		t.Errorf("Settle is not idempotent: %+v then %+v", a, b)
	}
}

func TestRegenBonusIsCapped(t *testing.T) {
	c := cfg(t)
	base := RegenPeriodMillis(c, Bonuses{})

	var atCap Bonuses
	atCap.Add(BucketEnergyRegen, 6000) // +60%, exactly the cap
	var wayOver Bonuses
	wayOver.Add(BucketEnergyRegen, 500000) // absurd stack

	if RegenPeriodMillis(c, atCap) != RegenPeriodMillis(c, wayOver) {
		t.Error("energy regen exceeded its cap — this is the ceiling on the entire gold supply")
	}
	if RegenPeriodMillis(c, atCap) >= base {
		t.Error("regen bonus did not speed regeneration up")
	}
}

func TestMaxEnergyDoesNotChangeRegenRate(t *testing.T) {
	// The central design statement: Max Energy is "how long can I be away",
	// regen is "how much do I earn per day". If buying max energy also raised
	// throughput, income would be unbounded.
	c := cfg(t)
	period := RegenPeriodMillis(c, Bonuses{})
	small := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, MaxEnergy(c, 1, 0, 0), period, t0.Add(10*time.Minute))
	large := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, MaxEnergy(c, 1, 100, 0), period, t0.Add(10*time.Minute))
	if small.Milli != large.Milli {
		t.Errorf("max energy changed accrual rate: %d vs %d", small.Milli, large.Milli)
	}

	// The same has to hold for the level term. The ceiling now grows with level
	// so that a long absence is not thrown away; if it also sped regeneration up,
	// income would compound with level and the gold supply would be unbounded --
	// which is the one invariant the whole economy rests on.
	lowLevel := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, MaxEnergy(c, 1, 0, 0), period, t0.Add(10*time.Minute))
	highLevel := Settle(EnergyState{Milli: 0, UpdatedAt: t0}, MaxEnergy(c, 60, 0, 0), period, t0.Add(10*time.Minute))
	if lowLevel.Milli != highLevel.Milli {
		t.Errorf("level changed accrual rate: %d vs %d", lowLevel.Milli, highLevel.Milli)
	}
	if MaxEnergy(c, 60, 0, 0) <= MaxEnergy(c, 1, 0, 0) {
		t.Error("the pool did not grow with level, so a long absence is still wasted")
	}
}

func TestSpendRefusesWhenShort(t *testing.T) {
	s := EnergyState{Milli: 4_999, UpdatedAt: t0}
	if _, ok := Spend(s, 5); ok {
		t.Error("spent 5 energy with only 4.999")
	}
	if out, ok := Spend(s, 4); !ok || out.Milli != 999 {
		t.Errorf("spend 4 = %+v ok=%v, want 999 milli", out, ok)
	}
}

// ---------------------------------------------------------------- buckets ---

func TestApplyBucketFloorsAndCaps(t *testing.T) {
	var b Bonuses
	b.Add(BucketCollectIncome, 2500) // +25%
	if got := ApplyBucket(7, b, BucketCollectIncome); got != 8 {
		t.Errorf("7 * 1.25 = %d, want 8 (floored from 8.75)", got)
	}
	var over Bonuses
	over.Add(BucketCollectIncome, 999999)
	if got, want := ApplyBucket(100, over, BucketCollectIncome), int64(250); got != want {
		t.Errorf("uncapped bonus applied: %d, want %d (+150%% cap)", got, want)
	}
}

func TestApplyBucketIsAdditiveNotMultiplicative(t *testing.T) {
	// Six +25% upgrades must be +150%, not 3.8x. Multiplicative stacking is how
	// these economies run away from their sinks.
	var b Bonuses
	for i := 0; i < 6; i++ {
		b.Add(BucketCollectIncome, 2500)
	}
	if got, want := ApplyBucket(1000, b, BucketCollectIncome), int64(2500); got != want {
		t.Errorf("six +25%% bonuses gave %d, want %d", got, want)
	}
}

// ------------------------------------------------------------ progression ---

func TestAwardXPHandlesMultipleLevelsAtOnce(t *testing.T) {
	c := cfg(t)
	up := AwardXP(c, 1, 0, 100_000, Bonuses{})
	if up.LevelsGained < 2 {
		t.Fatalf("a huge award gained only %d level(s)", up.LevelsGained)
	}
	perLevel := int64(c.Progression.StatPointsPerLevel)
	if perLevel < 1 {
		t.Fatal("stat_points_per_level is not configured")
	}
	if up.StatPoints != int64(up.LevelsGained)*perLevel {
		t.Errorf("stat points %d != %d levels x %d per level",
			up.StatPoints, up.LevelsGained, perLevel)
	}
	if !up.Refilled {
		t.Error("levelling up should refill energy")
	}
}

func TestAwardXPStopsAtLevelCap(t *testing.T) {
	c := cfg(t)
	up := AwardXP(c, c.Progression.LevelCap, 0, 1<<40, Bonuses{})
	if up.Level != c.Progression.LevelCap {
		t.Errorf("level %d exceeded the cap %d", up.Level, c.Progression.LevelCap)
	}
	if up.XP != 0 {
		t.Errorf("XP accumulated past the cap: %d", up.XP)
	}
}

func TestAwardXPNoGainDoesNothing(t *testing.T) {
	c := cfg(t)
	up := AwardXP(c, 5, 42, 0, Bonuses{})
	if up.Level != 5 || up.XP != 42 || up.LevelsGained != 0 {
		t.Errorf("zero XP changed state: %+v", up)
	}
}

// --------------------------------------------------------------- collect ----

func TestCollectUsesTheBonusBeforeTheMilestone(t *testing.T) {
	// On the 25th collect the player is still on the pre-milestone rate; the
	// bonus applies from the 26th. The client predicts pessimistically for
	// exactly this reason, so server and client must agree.
	c := cfg(t)
	job := c.Job("grapes")

	at24 := Collect(c, job, 24, Bonuses{})
	at25 := Collect(c, job, 25, Bonuses{})

	if at24.MilestoneHit == nil {
		t.Error("the 25th collect should report crossing the milestone")
	}
	if at24.MasteryBonusBP != 500 {
		t.Errorf("mastery after 25 collects = %d bp, want 500", at24.MasteryBonusBP)
	}
	// Grapes is 2 gold; +5% floors back to 2, so compare a job with headroom.
	big := c.Job("dragon_hoard")
	before := Collect(c, big, 24, Bonuses{})
	after := Collect(c, big, 25, Bonuses{})
	if after.Gold <= before.Gold {
		t.Errorf("mastery did not raise gold: %d then %d", before.Gold, after.Gold)
	}
	_ = at25
}

func TestCollectMasteryIsCappedWithOtherBonuses(t *testing.T) {
	c := cfg(t)
	job := c.Job("dragon_hoard")
	var huge Bonuses
	huge.Add(BucketCollectIncome, 100000) // absurd upgrade stack
	got := Collect(c, job, 1_000_000, huge)
	want := job.BaseGold * (10000 + Caps[BucketCollectIncome]) / 10000
	if got.Gold != want {
		t.Errorf("mastery + upgrades bypassed the cap: %d, want %d", got.Gold, want)
	}
}

func TestCollectNeverPaysZero(t *testing.T) {
	c := cfg(t)
	for _, j := range c.Jobs.Jobs {
		r := Collect(c, &j, 0, Bonuses{})
		if r.Gold <= 0 || r.XP <= 0 {
			t.Errorf("job %q pays gold=%d xp=%d", j.ID, r.Gold, r.XP)
		}
	}
}

func TestAwardXPReportsDeltasNotTotals(t *testing.T) {
	// The contract a caller has to know: StatPoints and Diamonds are what THIS
	// award earned, counted from zero, because ApplyCollect adds them to the row.
	//
	// CollectBatch got this wrong in both directions at once -- it seeded its
	// running totals with the player's current balance and then ASSIGNED each
	// award's delta over the last -- so a batch that levelled on its first tap
	// and not on its last credited nothing for the level, and reported a negative
	// diamond gain to the client.
	c := cfg(t)

	// An award far too small to level: no level, so no reward.
	none := AwardXP(c, 1, 0, 1, Bonuses{})
	if none.LevelsGained != 0 || none.StatPoints != 0 || none.Diamonds != 0 {
		t.Fatalf("an award that did not level still paid out: %+v", none)
	}

	// One that levels several times pays for every level, not just the last.
	big := AwardXP(c, 1, 0, 100_000, Bonuses{})
	if big.LevelsGained < 2 {
		t.Fatalf("expected several levels from a large award, got %d", big.LevelsGained)
	}
	wantStat := int64(big.LevelsGained) * int64(c.Progression.StatPointsPerLevel)
	if big.StatPoints != wantStat {
		t.Errorf("stat points = %d, want %d (one grant per level gained)", big.StatPoints, wantStat)
	}
	wantGems := int64(big.LevelsGained) * c.Progression.LevelupDiamonds
	if big.Diamonds != wantGems {
		t.Errorf("diamonds = %d, want %d", big.Diamonds, wantGems)
	}

	// And the deltas do not carry the player's existing balance: the same award
	// pays the same whatever the caller already holds, because the caller is the
	// one that has to accumulate.
	again := AwardXP(c, 1, 0, 100_000, Bonuses{})
	if again.StatPoints != big.StatPoints || again.Diamonds != big.Diamonds {
		t.Error("AwardXP is not a pure function of its arguments")
	}
}
