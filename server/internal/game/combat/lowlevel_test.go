package combat

import (
	"fmt"
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// realArmy builds what a player of this level actually fields: a hero with
// allocated points plus n soldiers, using the real stat derivations.
func realArmy(c *gameconfig.Bundle, id string, level int64, soldiers int, tier string) Army {
	a := Army{PlayerID: id, Name: id, Level: level}
	pts := level - 1
	atk, def := army.HeroBase(c, level, pts/2, pts-pts/2)
	a.Units = append(a.Units, Combatant{
		ID: id + "-hero", Name: "hero", IsHero: true,
		Attack: atk, Defense: def, HP: army.HeroHP(c, level, def),
	})
	for i := 0; i < soldiers; i++ {
		sa, sd, shp := army.SoldierBase(c, "peasant", tier)
		a.Units = append(a.Units, Combatant{
			ID: fmt.Sprintf("%s-s%d", id, i), Name: "peasant", Tier: tier,
			Attack: sa, Defense: sd, HP: army.UnitHP(c, shp, sd, level),
		})
	}
	return a
}

// TestRoundCountByLevel keeps battle length honest across the whole curve, using
// rosters a real player would actually field rather than synthetic ones.
//
// Two things matter here. A fight that runs long is a replay nobody watches, and
// a fight that reaches the round cap is decided on health fraction rather than a
// kill — which players read as arbitrary. The cap must stay a safety net.
func TestRoundCountByLevel(t *testing.T) {
	if testing.Short() {
		t.Skip("runs 2400 battles")
	}
	c := cfg(t)
	fmt.Printf("%6s %10s %10s %10s %10s\n", "level", "soldiers", "avg rounds", "p95 rounds", "timeout %")
	for _, k := range []struct {
		level    int64
		soldiers int
	}{{4, 1}, {10, 2}, {20, 4}, {30, 6}, {45, 8}, {60, 10}} {
		const N = 400
		total, timeouts := 0, 0
		rounds := make([]int, 0, N)
		for i := 0; i < N; i++ {
			rng := rand.New(rand.NewPCG(uint64(i), 11))
			rep := Simulate(c, rng, uint64(i),
				realArmy(c, "A", k.level, k.soldiers, "uncommon"),
				realArmy(c, "D", k.level, k.soldiers, "uncommon"))
			total += rep.Rounds
			rounds = append(rounds, rep.Rounds)
			if rep.TimedOut {
				timeouts++
			}
		}
		for i := 1; i < len(rounds); i++ {
			for j := i; j > 0 && rounds[j] < rounds[j-1]; j-- {
				rounds[j], rounds[j-1] = rounds[j-1], rounds[j]
			}
		}
		avg := float64(total) / N
		timeoutPct := float64(timeouts) * 100 / N
		fmt.Printf("%6d %10d %10.1f %10d %9.1f%%\n",
			k.level, k.soldiers, avg, rounds[int(float64(N)*0.95)], timeoutPct)

		if avg > 40 {
			t.Errorf("level %d: average fight is %.1f rounds; the replay becomes something to skip", k.level, avg)
		}
		if timeoutPct > 1.5 {
			t.Errorf("level %d: %.1f%% of fights hit the round cap and were decided on health fraction, "+
				"which makes MAX_ROUNDS a design element rather than a safety net", k.level, timeoutPct)
		}
	}
}
