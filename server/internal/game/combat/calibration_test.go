package combat

import (
	"fmt"
	"math/rand/v2"
	"testing"

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

// makeArmy builds a symmetric roster whose Might scales with `scale` basis
// points, so two armies can be compared at a known ratio.
func makeArmy(id string, side Side, units int, scaleBP int64, level int64) Army {
	a := Army{PlayerID: id, Name: id, Level: level}
	for i := 0; i < units; i++ {
		a.Units = append(a.Units, Combatant{
			ID:      fmt.Sprintf("%s-%d", id, i),
			Name:    fmt.Sprintf("%s unit %d", id, i),
			Attack:  250 * scaleBP / 10000,
			Defense: 250 * scaleBP / 10000,
			Speed:   40 * scaleBP / 10000,
			HP:      1200 * scaleBP / 10000,
		})
	}
	return a
}

// TestCombatCalibration is the gate the design asks CI to hold.
//
// The win-probability table in docs/design/economy.md is a MODEL. The simulator
// must be measured against it, because front-line ordering, wasted excess damage
// and rage all bias the result away from the closed form. If this drifts, either
// the simulator changed or FORTUNE_SIGMA needs re-deriving — and either way the
// game's most important number is no longer what the document claims.
func TestCombatCalibration(t *testing.T) {
	if testing.Short() {
		t.Skip("calibration runs 6 x 4000 battles")
	}
	c := cfg(t)

	// Might scales with sqrt(ATK*EHP), and both scale linearly with scaleBP, so a
	// stat scale of X gives a Might ratio of X.
	// Targets are the design's win-probability table. Tolerances are tight
	// because FORTUNE_SIGMA has been calibrated against this simulator (0.50, not
	// the 0.38 the closed-form model suggested) — so drift here means a real
	// change in combat, not sampling noise.
	//
	// The 1.00 row sits slightly above 50% on purpose: a speed tie gives first
	// strike to the attacker, which is worth about two points. The defender's
	// Home Ground bonus offsets most of it.
	cases := []struct {
		ratio     float64
		wantWinPc float64
		tolerance float64
	}{
		{0.80, 20.4, 4.0},
		{1.00, 52.0, 4.0},
		{1.10, 63.8, 4.0},
		{1.20, 75.0, 4.0},
		{1.35, 86.7, 4.0},
		{1.50, 93.4, 4.0},
	}

	const N = 6000
	for _, k := range cases {
		scale := int64(k.ratio * 10000)
		wins := 0
		for i := 0; i < N; i++ {
			rng := rand.New(rand.NewPCG(uint64(i), 0xC0FFEE))
			att := makeArmy("A", SideAttacker, 5, scale, 30)
			def := makeArmy("D", SideDefender, 5, 10000, 30)
			if Simulate(c, rng, uint64(i), att, def).Winner == SideAttacker {
				wins++
			}
		}
		got := float64(wins) * 100 / N
		t.Logf("Might ratio %.2f -> attacker wins %.1f%% (model says %.1f%%)", k.ratio, got, k.wantWinPc)
		if diff := got - k.wantWinPc; diff > k.tolerance || diff < -k.tolerance {
			t.Errorf("ratio %.2f: attacker won %.1f%%, model says %.1f%% (tolerance +-%.1f)",
				k.ratio, got, k.wantWinPc, k.tolerance)
		}
	}
}

func TestBattlesAlwaysTerminate(t *testing.T) {
	// Rage guarantees termination. If it ever stops doing so, MAX_ROUNDS turns
	// from a safety net into a design element and every fight ends on health
	// fraction, which players read as a bug.
	c := cfg(t)
	timeouts := 0
	const N = 600
	for i := 0; i < N; i++ {
		rng := rand.New(rand.NewPCG(uint64(i), 7))
		// Deliberately tanky and symmetric: the hardest case to resolve.
		att := makeArmy("A", SideAttacker, 10, 10000, 60)
		def := makeArmy("D", SideDefender, 10, 10000, 60)
		rep := Simulate(c, rng, uint64(i), att, def)
		if rep.TimedOut {
			timeouts++
		}
		if rep.Rounds > c.Soldiers.Combat.MaxRounds {
			t.Fatalf("battle ran %d rounds, past the %d cap", rep.Rounds, c.Soldiers.Combat.MaxRounds)
		}
	}
	if timeouts*100/N > 5 {
		t.Errorf("%d/%d symmetric battles hit the round cap; rage is not resolving fights", timeouts, N)
	}
}

func TestReplayIsReproducible(t *testing.T) {
	// An audit must be able to re-run a battle and get the identical log.
	c := cfg(t)
	run := func() *Replay {
		rng := rand.New(rand.NewPCG(99, 100))
		return Simulate(c, rng, 99, makeArmy("A", SideAttacker, 4, 11000, 20), makeArmy("D", SideDefender, 4, 10000, 20))
	}
	a, b := run(), run()
	if a.Winner != b.Winner || a.Rounds != b.Rounds || len(a.Events) != len(b.Events) {
		t.Fatalf("same seed diverged: %s/%d/%d vs %s/%d/%d",
			a.Winner, a.Rounds, len(a.Events), b.Winner, b.Rounds, len(b.Events))
	}
	for i := range a.Events {
		if a.Events[i] != b.Events[i] {
			t.Fatalf("event %d diverged: %+v vs %+v", i, a.Events[i], b.Events[i])
		}
	}
}

func TestStrongerArmyUsuallyWins(t *testing.T) {
	c := cfg(t)
	wins := 0
	for i := 0; i < 400; i++ {
		rng := rand.New(rand.NewPCG(uint64(i), 3))
		rep := Simulate(c, rng, uint64(i),
			makeArmy("A", SideAttacker, 6, 20000, 30),
			makeArmy("D", SideDefender, 6, 10000, 30))
		if rep.Winner == SideAttacker {
			wins++
		}
	}
	if wins < 380 {
		t.Errorf("a 2x army won only %d/400 — power is not deciding fights", wins)
	}
}

func TestEmptyArmyLoses(t *testing.T) {
	c := cfg(t)
	rng := rand.New(rand.NewPCG(1, 1))
	rep := Simulate(c, rng, 1, Army{PlayerID: "A"}, makeArmy("D", SideDefender, 1, 10000, 5))
	if rep.Winner != SideDefender {
		t.Errorf("an empty attacking army won: %s", rep.Winner)
	}
}

func TestReplayCarriesEnoughToAnimate(t *testing.T) {
	c := cfg(t)
	rng := rand.New(rand.NewPCG(5, 5))
	rep := Simulate(c, rng, 5, makeArmy("A", SideAttacker, 3, 10500, 25), makeArmy("D", SideDefender, 3, 10000, 25))

	if rep.FortuneABP <= 0 || rep.FortuneDBP <= 0 {
		t.Error("fortune was not rolled; the client cannot show the pre-battle die")
	}
	var hits, deaths int
	for _, e := range rep.Events {
		switch e.Kind {
		case "hit":
			hits++
			if e.Src == "" || e.Dst == "" || e.Damage <= 0 {
				t.Fatalf("a hit event is not animatable: %+v", e)
			}
		case "death":
			deaths++
		}
	}
	if hits == 0 {
		t.Error("no hit events to animate")
	}
	if deaths == 0 {
		t.Error("nobody died, yet the battle ended")
	}
}
