// Package boss is the pure half of the kingdom's boss raid: how big the beast
// is, what a blow takes out of it, and who has earned what when it falls.
//
// Pure like the rest of internal/game. Time arrives as a parameter and the roll
// arrives as a seeded generator; nothing here knows about a database.
package boss

import (
	"math/rand/v2"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// HP is the wall a kingdom has to bring down.
//
// The kingdom's whole Might, times the blows each member has, times the
// balance's calibrated share -- and a tenth more for every time this kingdom
// has already put a beast down. That is what makes it the same siege for five
// lords and for twenty: what changes is how many swords are raised at it, not
// whether the wall can be broken at all.
func HP(cfg *gameconfig.Bundle, kingdomMight int64, level int) int64 {
	c := cfg.Boss
	if kingdomMight <= 0 || c.HitsPerMember <= 0 {
		return 0
	}
	hp := kingdomMight * int64(c.HitsPerMember) * c.HPPerMightBP / 10000
	for i := 1; i < level; i++ {
		hp = hp * c.HPGrowthBP / 10000
	}
	if hp < 1 {
		hp = 1
	}
	return hp
}

// Army is the beast as it fights: one figure with what is left of its health.
//
// Its own numbers are shares of an AVERAGE member's Might, because what it
// swings at is one lord at a time. The kingdom's size lives in the health.
func Army(cfg *gameconfig.Bundle, b *gameconfig.Boss, avgMight, hpLeft int64, level int64) combat.Army {
	if b == nil {
		return combat.Army{}
	}
	atk := avgMight * b.AttackBP / 10000
	def := avgMight * b.DefenseBP / 10000
	if atk < 1 {
		atk = 1
	}
	if hpLeft < 1 {
		hpLeft = 1
	}
	return combat.Army{
		PlayerID: "boss", Name: b.Name, Level: level,
		Units: []combat.Combatant{{
			ID: b.ID, Name: b.Name, IsHero: true,
			Attack: atk, Defense: def, Speed: 0, HP: hpLeft,
		}},
	}
}

// Might is what a beast would be worth on the same scale a lord is measured on,
// for the screen to say whether a kingdom is out of its depth.
func Might(cfg *gameconfig.Bundle, b *gameconfig.Boss, avgMight, hpLeft int64, level int64) int64 {
	if b == nil {
		return 0
	}
	atk := avgMight * b.AttackBP / 10000
	def := avgMight * b.DefenseBP / 10000
	return army.UnitMight(atk, army.EffectiveHP(cfg, hpLeft, def, level))
}

// Blow is one lord's strike: a real fight, cut to the balance's rounds.
//
// What the lord did to the beast in those rounds is their damage -- so a
// stronger army digs deeper, and a lord who falls early digs less. The beast
// never "wins": it either falls, or the rounds run out and it is still standing.
func Blow(cfg *gameconfig.Bundle, rng *rand.Rand, seed uint64, mine combat.Army, myMight int64,
	b *gameconfig.Boss, avgMight, hpLeft int64, level int64) (*combat.Replay, int64) {

	rounds := cfg.Boss.RoundsPerHit
	beast := Army(cfg, b, avgMight, hpLeft, level)
	// The beast stands on its own ground, as every defender does, and the blow
	// is the ordinary fight the whole game is decided by -- only shorter.
	rep := combat.SimulateWith(cfg, rng, seed, mine, beast, combat.Options{MaxRounds: &rounds})
	rep.AttackerMight, rep.DefenderMight = myMight, Might(cfg, b, avgMight, hpLeft, level)
	dealt := rep.AttackerDamage
	if dealt > hpLeft {
		dealt = hpLeft
	}
	if dealt < 0 {
		dealt = 0
	}
	return rep, dealt
}

// EnergyCost is what one blow costs a lord of this level: what a raid costs, so
// a blow and a raid are the same decision about the same pool.
func EnergyCost(cfg *gameconfig.Bundle, level int64) int64 {
	c := cfg.Boss
	cost := c.EnergyBase + level*c.EnergyPerLevel/10000
	if cost < 1 {
		cost = 1
	}
	return cost
}

// Valour is the damage a lord must have done to be counted brave: the balance's
// share of an EQUAL share of what the kingdom did.
//
// A share of the total rather than a fixed figure, because the total is what the
// kingdom could manage: in a kingdom of five who all turned up, everyone is
// brave; in one where nine watched and one fought, only the one is.
func Valour(cfg *gameconfig.Bundle, total int64, fighters int) int64 {
	if fighters <= 0 || total <= 0 {
		return 0
	}
	need := total / int64(fighters) * cfg.Boss.ValourShareBP / 10000
	if need < 1 {
		need = 1
	}
	return need
}

// Chest is what one of the three pays at this beast's level: the written grant,
// with its wages and its diamonds grown by the balance's own step. A harder
// beast pays more, by the same rule that makes it harder.
func Chest(cfg *gameconfig.Bundle, chest *gameconfig.BossChest, level int) gameconfig.RewardBundle {
	if chest == nil {
		return gameconfig.RewardBundle{}
	}
	// The step lives in gameconfig, because the validator has to grow the same
	// chest to the same level to ask whether the letter could still be sent.
	return cfg.Boss.GrownChest(chest, level)
}

// Earned is which chests a lord has earned this cycle.
type Earned struct {
	Hit    bool
	Valour bool
	Kill   bool
}

// Earns works out a lord's chests from what they did and what the cycle did.
func Earns(cfg *gameconfig.Bundle, damage, total int64, fighters int, killed bool) Earned {
	if damage <= 0 {
		return Earned{}
	}
	return Earned{
		Hit:    true,
		Valour: damage >= Valour(cfg, total, fighters),
		Kill:   killed,
	}
}

// Has reports whether a chest's own condition is one of the earned ones.
func (e Earned) Has(need string) bool {
	switch need {
	case gameconfig.BossNeedHit:
		return e.Hit
	case gameconfig.BossNeedValour:
		return e.Valour
	case gameconfig.BossNeedKill:
		return e.Kill
	}
	return false
}
