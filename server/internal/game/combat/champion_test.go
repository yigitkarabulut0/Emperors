package combat

import (
	"fmt"
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
)

// The champion is the roster added up, and this is the sum that matters: what
// it costs to kill it. A roster is killed by dealing the sum of its EFFECTIVE
// hit points -- each unit's hp scaled up by its own armour -- because only the
// front rank was ever struck. If the champion did not absorb the same, every
// battle in the game would be a different length and the win curve would move.
func TestChampionTakesWhatTheRosterWouldHave(t *testing.T) {
	c := cfg(t)
	roster := Army{PlayerID: "p", Name: "P", Level: 30}
	for i, def := range []int64{40, 250, 900, 1500} {
		roster.Units = append(roster.Units, Combatant{
			ID: fmt.Sprintf("u%d", i), Attack: 100 + int64(i)*70,
			Defense: def, Speed: 20 + int64(i)*5, HP: 500 + int64(i)*300,
		})
	}

	var wantEHP, wantATK, wantSPD, wantHP int64
	for _, u := range roster.Units {
		dr := army.DamageReductionBP(c, u.Defense, roster.Level)
		wantEHP += u.HP * 10000 / (10000 - dr)
		wantATK += u.Attack
		wantSPD += u.Speed
		wantHP += u.HP
	}

	ch := buildChampion(c, roster, SideAttacker, 10000)
	if ch == nil {
		t.Fatal("no champion")
	}
	if ch.Attack != wantATK {
		t.Errorf("attack %d, the roster's units add to %d", ch.Attack, wantATK)
	}
	if ch.Speed != wantSPD {
		t.Errorf("speed %d, the roster adds to %d", ch.Speed, wantSPD)
	}
	if ch.maxHP != wantHP {
		t.Errorf("hp %d, the roster adds to %d", ch.maxHP, wantHP)
	}
	gotEHP := ch.maxHP * 10000 / (10000 - ch.drBP)
	// Integer division loses a little; a tenth of a percent is the tolerance.
	if diff := gotEHP - wantEHP; diff > wantEHP/1000 || diff < -wantEHP/1000 {
		t.Errorf("takes %d damage to kill, the roster took %d", gotEHP, wantEHP)
	}
}

// One blow each per round, the attacker first. That is the whole shape of the
// fight, and the screen is built to it.
func TestOneBlowEachPerRoundStartingWithTheAttacker(t *testing.T) {
	c := cfg(t)
	rng := rand.New(rand.NewPCG(7, 0xC0FFEE))
	rep := Simulate(c, rng, 7, makeArmy("A", SideAttacker, 5, 10000, 30),
		makeArmy("D", SideDefender, 5, 10000, 30))

	if rep.Rounds < 2 {
		t.Fatalf("only %d rounds; nothing to check", rep.Rounds)
	}
	perRound := map[int]map[Side]int{}
	order := map[int][]Side{}
	for _, e := range rep.Events {
		if e.Kind != "hit" && e.Kind != "dodge" {
			continue
		}
		if perRound[e.Round] == nil {
			perRound[e.Round] = map[Side]int{}
		}
		perRound[e.Round][e.Side]++
		order[e.Round] = append(order[e.Round], e.Side)
	}
	for round, byside := range perRound {
		for side, n := range byside {
			if n != 1 {
				t.Errorf("round %d: side %s swung %d times, not once", round, side, n)
			}
		}
		if len(order[round]) > 0 && order[round][0] != SideAttacker {
			t.Errorf("round %d opened with %s; the attacker always opens", round, order[round][0])
		}
	}
}

// The screen draws two faces and two bars, and needs the ids on the events to
// name the sides it drew.
func TestEventsNameTheChampionsTheScreenDrew(t *testing.T) {
	c := cfg(t)
	rng := rand.New(rand.NewPCG(3, 0xC0FFEE))
	att := makeArmy("A", SideAttacker, 4, 12000, 30)
	def := makeArmy("D", SideDefender, 4, 10000, 30)
	rep := Simulate(c, rng, 3, att, def)

	seen := map[string]bool{}
	rounds := 0
	for _, e := range rep.Events {
		switch e.Kind {
		case "round":
			rounds++
		case "hit", "hp", "death":
			if e.Dst != "" {
				seen[e.Dst] = true
			}
		}
	}
	if rounds == 0 {
		t.Error("no round markers; the screen has nothing to count")
	}
	for _, id := range []string{att.PlayerID, def.PlayerID} {
		if !seen[id] {
			t.Errorf("no event names %q, so the screen cannot find the bar to drain", id)
		}
	}
}
