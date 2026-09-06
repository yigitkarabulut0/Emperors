// Package army turns a roster into combat numbers: per-unit stats, effective
// HP, and the single Might score used for matchmaking and leaderboards.
//
// Pure, like the rest of internal/game. Integer maths throughout, including the
// square root, so Might is identical on every machine that computes it.
package army

import (
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Unit is one combatant: the player, or a soldier.
type Unit struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	IsHero bool   `json:"is_hero"`
	Type   string `json:"type,omitempty"`
	Tier   string `json:"tier,omitempty"`
	Level  int64  `json:"level"`

	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	Speed   int64 `json:"speed"`
	HP      int64 `json:"hp"`
	EHP     int64 `json:"ehp"`
}

// Gear is the summed contribution of whatever a unit has equipped.
type Gear struct{ Attack, Defense, Speed int64 }

// SoldierBase derives a soldier's stats before equipment.
//
// Type and tier, and nothing else. A soldier does not have a level: what it is
// when you recruit it is what it stays.
//
// It used to carry (1 + 0.09 * soldier_level), and that single term made the
// tier ladder meaningless. Adjacent tiers are 1.35x to 1.46x apart, so four to
// five levels of Training was enough for a tier to overtake the one above it --
// a trained epic genuinely out-hit an untrained legendary, which is exactly
// backwards from what the rarity on the card promises. With the level term gone
// the ladder is strictly ordered: a legendary always beats an epic.
//
// A common Gladiator still lands near a rare Peasant. That overlap is the point
// and it survives: the TYPE matters beyond the tier roll, which is what
// justifies the 40x price gap and stops a lucky cheap roll from making the
// expensive option pointless.
func SoldierBase(cfg *gameconfig.Bundle, typeID, tier string) (attack, defense, hp int64) {
	t := cfg.SoldierType(typeID)
	if t == nil {
		return 0, 0, 0
	}
	tierBP := cfg.Items.TierMultBP[tier]

	scale := func(v int64) int64 {
		return (v*tierBP + 5000) / 10000
	}
	return scale(t.Attack), scale(t.Defense), scale(t.HP)
}

// HeroBase derives the player's own stats before equipment.
//
// The player is the only thing in the game that grows with level, and it grows
// in STEPS: every fifth level hands over a lump of attack and defense. It used
// to be a flat per-level trickle, which meant the number went up on its own with
// no decision attached -- and, alongside soldiers that also grew with level, it
// made "what level are you" the whole of power. Everything past the step comes
// from spending stat points, which is a choice the player makes.
//
// The floor is load-bearing: it guarantees a player with no soldiers is never a
// zero, so they can still win fights and progress. That was an explicit
// requirement, not a nicety.
func HeroBase(cfg *gameconfig.Bundle, level, ptsAttack, ptsDefense int64) (attack, defense int64) {
	p := cfg.Soldiers.Player
	steps := int64(0)
	if p.LevelsPerStatStep > 0 {
		steps = level / p.LevelsPerStatStep
	}
	base := p.BaseStat + p.StatStep*steps
	return base + p.PerStatPoint*ptsAttack, base + p.PerStatPoint*ptsDefense
}

// HeroHP derives the player's hit points.
func HeroHP(cfg *gameconfig.Bundle, level, defense int64) int64 {
	p := cfg.Soldiers.Player
	c := cfg.Soldiers.Combat
	raw := p.BaseHP + p.HPPerLevel*level + defense*c.HPPerDefenseBP/10000
	return raw * (10000 + c.HPLevelBonusBP*level) / 10000
}

// UnitHP derives a soldier's hit points from its base HP and total defense.
//
// Defense buys HP as well as damage reduction — a deliberate double-dip. Without
// it, Attack would dominate, because in a volley system every living unit
// contributes damage while only the front unit takes it, making Attack worth
// roughly twice as much per point.
func UnitHP(cfg *gameconfig.Bundle, baseHP, defense, ownerLevel int64) int64 {
	c := cfg.Soldiers.Combat
	raw := baseHP + defense*c.HPPerDefenseBP/10000
	return raw * (10000 + c.HPLevelBonusBP*ownerLevel) / 10000
}

// DamageReductionBP is the fraction of incoming damage a unit shrugs off, in
// basis points.
//
// Normalised by the owner's level so armour scales against your own tier rather
// than making a high-level player immune to everyone below them. Hard-capped, or
// a stacked-defense build becomes literally unkillable and the arena stalls.
func DamageReductionBP(cfg *gameconfig.Bundle, defense, ownerLevel int64) int64 {
	c := cfg.Soldiers.Combat
	k := c.DRLevelCoef*ownerLevel + c.DRBase
	if defense <= 0 {
		return 0
	}
	bp := defense * 10000 / (defense + k)
	if bp > c.DRCapBP {
		return c.DRCapBP
	}
	return bp
}

// EffectiveHP is hit points scaled by damage reduction: how much raw damage a
// unit actually absorbs before dying.
func EffectiveHP(cfg *gameconfig.Bundle, hp, defense, ownerLevel int64) int64 {
	drBP := DamageReductionBP(cfg, defense, ownerLevel)
	remaining := 10000 - drBP
	if remaining <= 0 {
		remaining = 1
	}
	return hp * 10000 / remaining
}

// Totals is the aggregate of a whole army.
type Totals struct {
	Attack int64 `json:"attack"`
	EHP    int64 `json:"ehp"`
	Might  int64 `json:"might"`
	Units  int   `json:"units"`
}

// Sum aggregates units into army totals.
//
// Might = 2*sqrt(ArmyATK * ArmyEHP) — the geometric mean of offence and
// survivability. It is monotone increasing in every stat, which matchmaking and
// an honest "you are stronger" UI both require. It is also exactly the quantity
// the battle simulation decides on: attack sums because every living unit fires,
// and effective HP sums because only the front unit is hit. Proxy and simulation
// agree by construction rather than by tuning.
func Sum(units []Unit) Totals {
	var t Totals
	for _, u := range units {
		t.Attack += u.Attack
		t.EHP += u.EHP
		t.Units++
	}
	t.Might = 2 * isqrt(t.Attack*t.EHP)
	return t
}

// isqrt is an integer square root by Newton's method.
//
// Deliberately not math.Sqrt: Might feeds matchmaking and the leaderboard, and a
// float result could differ in the last bit between architectures, which would
// make two servers disagree about who is stronger.
func isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
