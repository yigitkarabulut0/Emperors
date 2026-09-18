package combat

import (
	"bytes"
	"encoding/json"
	"math/rand/v2"
	"testing"
)

// The seam Wave 7 opened, and the promise it was opened on.
//
// There is ONE battle in this game. Every screen that shows a fight -- a raid,
// the arena, a bounty, a campaign stage, and the kingdom boss after it -- is
// showing this package's work, and a second simulator for PvE would be the
// surest way to end up with two games that disagree about what a sword is worth.
// So Simulate did not fork: it became SimulateWith with nothing turned.

func armies(t *testing.T) (Army, Army) {
	t.Helper()
	return makeArmy("att", SideAttacker, 6, 10000, 30),
		makeArmy("def", SideDefender, 6, 10500, 30)
}

func TestSimulateIsSimulateWithNothingTurned(t *testing.T) {
	c := cfg(t)
	a, d := armies(t)
	for seed := uint64(1); seed <= 2000; seed++ {
		one, err := json.Marshal(Simulate(c, rand.New(rand.NewPCG(seed, seed^0x9e37)), seed, a, d))
		if err != nil {
			t.Fatal(err)
		}
		two, err := json.Marshal(SimulateWith(c, rand.New(rand.NewPCG(seed, seed^0x9e37)), seed, a, d, Options{}))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(one, two) {
			t.Fatalf("seed %d: the two entry points produced different battles\n  %s\n  %s", seed, one, two)
		}
	}
}

// And each knob has to bite, or it is a comment pretending to be code.

func TestHomeGroundCanBeTakenAway(t *testing.T) {
	c := cfg(t)
	a, d := armies(t)
	none := int64(0)
	var withGround, without int
	for seed := uint64(1); seed <= 400; seed++ {
		if Simulate(c, rand.New(rand.NewPCG(seed, 7)), seed, a, d).Winner == SideAttacker {
			withGround++
		}
		if SimulateWith(c, rand.New(rand.NewPCG(seed, 7)), seed, a, d,
			Options{HomeGroundBP: &none}).Winner == SideAttacker {
			without++
		}
	}
	if without <= withGround {
		t.Fatalf("the attacker won %d of 400 with the defender's ground and %d without it: "+
			"taking the ground away changed nothing", withGround, without)
	}
}

func TestTheRoundLimitCanBeShortened(t *testing.T) {
	c := cfg(t)
	a, d := armies(t)
	one := 1
	rep := SimulateWith(c, rand.New(rand.NewPCG(3, 3)), 3, a, d, Options{MaxRounds: &one})
	if rep.Rounds != 1 {
		t.Fatalf("a one-round battle ran %d rounds", rep.Rounds)
	}
	if !rep.TimedOut {
		t.Fatal("a battle cut off after one round did not time out")
	}
}

// The health each side ends with is what the campaign reads its stars off, so
// it has to be the health the event log ends on.
func TestTheRecordedHealthIsWhatTheLogEndsOn(t *testing.T) {
	c := cfg(t)
	a, d := armies(t)
	for seed := uint64(1); seed <= 200; seed++ {
		rep := Simulate(c, rand.New(rand.NewPCG(seed, 11)), seed, a, d)
		last := map[Side]int64{}
		seen := map[Side]bool{}
		for _, e := range rep.Events {
			if e.Kind == "hp" {
				last[e.Side] = e.HPLeft
				seen[e.Side] = true
			}
		}
		// The loser is always on zero, and the winner's share must match the
		// last health the log showed for them.
		if rep.Winner == SideAttacker && rep.DefenderHPLeftBP != 0 && !rep.TimedOut {
			t.Fatalf("seed %d: the defender fell with %d bp left", seed, rep.DefenderHPLeftBP)
		}
		if seen[SideAttacker] && last[SideAttacker] == 0 && rep.AttackerHPLeftBP != 0 {
			t.Fatalf("seed %d: the attacker's last hp event was 0 and the replay says %d bp",
				seed, rep.AttackerHPLeftBP)
		}
		if rep.AttackerHPLeftBP < 0 || rep.AttackerHPLeftBP > 10000 {
			t.Fatalf("seed %d: attacker health left is %d bp", seed, rep.AttackerHPLeftBP)
		}
	}
}
