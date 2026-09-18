package boss

import (
	"fmt"
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
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

// A member of a kingdom, as one actually is at a level: the hero with the gear
// the shop would have sold them, and the roster cmd/seedbots builds.
//
// This is the same reference lord the campaign's ladder was cut against
// (scripts/gen-balance.py), because a wave that measured its content against a
// different imaginary player would be balancing against a different game.
func member(c *gameconfig.Bundle, level int64, tier string) (combat.Army, int64) {
	pts := level - 1
	atk, def := army.HeroBase(c, level, pts/2, pts-pts/2)
	var spd int64
	for _, slot := range []string{"weapon", "armor", "horse"} {
		base, ok := c.Items.SlotBase[slot]
		if !ok {
			continue
		}
		tierBP := c.Items.TierMultBP[tier]
		levelBP := 10000 + c.Items.LevelMultPerIlvlBP*level
		scale := func(v int64) int64 {
			if v == 0 {
				return 0
			}
			num := v * tierBP * levelBP
			return (num + 10000*10000/2) / (10000 * 10000)
		}
		atk += scale(base.Attack)
		def += scale(base.Defense)
		spd += scale(base.Speed)
	}
	hp := army.HeroHP(c, level, def)
	a := combat.Army{PlayerID: "lord", Name: "A Lord", Level: level}
	a.Units = append(a.Units, combat.Combatant{
		ID: "hero", Name: "A Lord", IsHero: true,
		Attack: atk, Defense: def, Speed: spd, HP: hp,
	})
	units := []army.Unit{{Attack: atk, EHP: army.EffectiveHP(c, hp, def, level)}}

	slots := int(level/4 + 1)
	if slots > 10 {
		slots = 10
	}
	for i := 0; i < slots; i++ {
		sa, sd, sh := army.SoldierBase(c, "mercenary", tier)
		shp := army.UnitHP(c, sh, sd, level)
		a.Units = append(a.Units, combat.Combatant{
			ID: fmt.Sprintf("s%d", i), Name: "Sellsword", Type: "mercenary", Tier: tier,
			Attack: sa, Defense: sd, HP: shp,
		})
		units = append(units, army.Unit{Attack: sa, EHP: army.EffectiveHP(c, shp, sd, level)})
	}
	return a, army.Sum(units).Might
}

// THE NUMBER THE WHOLE RAID RESTS ON.
//
// boss.json's hp_per_might_bp is the one figure between "no kingdom ever kills
// it" and "it falls to the first lord who logs in". What it really sets is the
// TURNOUT a kill needs: the share of a kingdom's blows that have to be raised
// before the beast goes down. The design asks for 65-80% -- a kingdom where
// three in four members turn up kills it, one where half do not.
//
// The only honest way to know is to fight it, so that is what this does: a
// kingdom of reference lords -- the same imaginary player the campaign's ladder
// was cut against -- spends its blows one at a time until the beast falls, and
// what share of the muster that took is measured.
//
// If this drifts, either the simulator changed or the share needs re-deriving,
// and either way the raid is no longer the fight the design asked for.
func TestABossNeedsMostOfTheKingdomToFall(t *testing.T) {
	if testing.Short() {
		t.Skip("the calibration fights 300 cycles")
	}
	c := cfg(t)
	for _, k := range []struct {
		name    string
		members int
		level   int64
		tier    string
	}{
		{"five lords of 20, rare gear", 5, 20, "rare"},
		{"ten lords of 30, epic gear", 10, 30, "epic"},
		{"twenty lords of 45, legendary gear", 20, 45, "legendary"},
		{"thirty lords of 60, mystic gear", 30, 60, "mystic"},
	} {
		var sum float64
		cycles := 60
		for cycle := 0; cycle < cycles; cycle++ {
			sum += turnoutToKill(c, k.members, k.level, k.tier, 1, uint64(cycle)*7919+1)
		}
		share := sum / float64(cycles) * 100
		t.Logf("%-34s a kill takes %.0f%% of the kingdom's blows", k.name, share)
		if share < 65 || share > 80 {
			t.Errorf("%s: a level-one beast falls to %.0f%% of the blows; the design asks for 65-80%%",
				k.name, share)
		}
	}
}

// And a kingdom that turns out in full must actually kill it -- the other half
// of the same number.
func TestAFullMusterKillsALevelOneBoss(t *testing.T) {
	c := cfg(t)
	kills, cycles := 0, 40
	for cycle := 0; cycle < cycles; cycle++ {
		if _, killed := fightCycle(c, 10, 30, "epic", 1, uint64(cycle)*7919+3); killed {
			kills++
		}
	}
	if kills != cycles {
		t.Errorf("a kingdom of ten that spent every blow killed a level-one beast %d times in %d",
			kills, cycles)
	}
}

// And it must harden: the same kingdom finds each level harder than the last,
// or a kingdom farms one beast for ever at the same price.
func TestABossHardensAsItFalls(t *testing.T) {
	c := cfg(t)
	last := 0.0
	for _, level := range []int{1, 3, 6} {
		var sum float64
		for cycle := 0; cycle < 30; cycle++ {
			sum += turnoutToKill(c, 10, 30, "epic", level, uint64(cycle)*104729+uint64(level))
		}
		share := sum / 30
		t.Logf("level %d takes %.0f%% of the kingdom's blows", level, share*100)
		if share <= last {
			t.Errorf("level %d falls to %.0f%% of the blows, no more than the level before it (%.0f%%)",
				level, share*100, last*100)
		}
		last = share
	}
}

// turnoutToKill is the share of a kingdom's blows a kill took, or 1 when the
// whole muster was not enough.
func turnoutToKill(c *gameconfig.Bundle, members int, level int64, tier string, bossLevel int,
	seed uint64) float64 {

	mine, might := member(c, level, tier)
	hp := HP(c, might*int64(members), bossLevel)
	blows := members * c.Boss.HitsPerMember
	rng := rand.New(rand.NewPCG(seed, seed^0x5eed))
	for i := 0; i < blows; i++ {
		_, dealt := Blow(c, rng, rng.Uint64(), mine, might, c.Boss.BossAt(0), might, hp, level)
		hp -= dealt
		if hp <= 0 {
			return float64(i+1) / float64(blows)
		}
	}
	return 1
}

// fightCycle spends a whole kingdom's blows on one beast and says what was left
// of it and whether it fell.
func fightCycle(c *gameconfig.Bundle, members int, level int64, tier string, bossLevel int,
	seed uint64) (float64, bool) {

	mine, might := member(c, level, tier)
	hp := HP(c, might*int64(members), bossLevel)
	full := hp
	rng := rand.New(rand.NewPCG(seed, seed^0x5eed))
	for m := 0; m < members && hp > 0; m++ {
		for h := 0; h < c.Boss.HitsPerMember && hp > 0; h++ {
			_, dealt := Blow(c, rng, rng.Uint64(), mine, might, c.Boss.BossAt(0), might, hp, level)
			hp -= dealt
		}
	}
	if hp < 0 {
		hp = 0
	}
	return float64(hp) / float64(full), hp <= 0
}
