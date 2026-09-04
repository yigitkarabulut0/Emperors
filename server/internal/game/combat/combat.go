// Package combat is the battle simulator: deterministic, seeded, and pure.
//
// The server simulates ONCE and persists the resulting event log; the client
// only animates it. That keeps cross-platform float determinism off the
// correctness path entirely. Inside the simulator the maths is integer
// throughout, so an audit re-run reproduces a battle exactly.
package combat

import (
	"math"
	"math/rand/v2"
	"sort"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Side identifies an army.
type Side string

const (
	SideAttacker Side = "a"
	SideDefender Side = "d"
)

// Combatant is one unit as it enters the battle. Everything is frozen here, so
// the replay stays valid even if the player later sells the sword they used.
type Combatant struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Tier    string `json:"tier,omitempty"`
	Type    string `json:"type,omitempty"`
	IsHero  bool   `json:"is_hero"`
	Attack  int64  `json:"attack"`
	Defense int64  `json:"defense"`
	Speed   int64  `json:"speed"`
	HP      int64  `json:"hp"`
}

// Army is one side's frozen roster.
type Army struct {
	PlayerID string      `json:"player_id"`
	Name     string      `json:"name"`
	Level    int64       `json:"level"`
	Units    []Combatant `json:"units"`
}

// Event is one thing the client animates.
type Event struct {
	Round  int    `json:"r"`
	Kind   string `json:"k"` // hit | dodge | death | round
	Side   Side   `json:"s,omitempty"`
	Src    string `json:"src,omitempty"`
	Dst    string `json:"dst,omitempty"`
	Damage int64  `json:"dmg,omitempty"`
	Crit   bool   `json:"crit,omitempty"`
	HPLeft int64  `json:"hp,omitempty"`
}

// Replay is the whole battle: inputs, outcome, and the event log.
type Replay struct {
	Version       int     `json:"v"`
	Seed          uint64  `json:"seed"`
	ConfigVersion int     `json:"balance_version"`
	FortuneABP    int64   `json:"fortune_a_bp"`
	FortuneDBP    int64   `json:"fortune_d_bp"`
	FirstSide     Side    `json:"order"`
	Rounds        int     `json:"rounds"`
	Winner        Side    `json:"winner"`
	TimedOut      bool    `json:"timed_out"`
	Attacker      Army    `json:"attacker"`
	Defender      Army    `json:"defender"`
	Events        []Event `json:"events"`
}

type unit struct {
	Combatant
	side  Side
	hp    int64
	maxHP int64
	level int64
}

func (u *unit) alive() bool { return u.hp > 0 }

// Simulate runs a battle to completion.
//
// The model is a volley with a front line: every living unit on a side
// contributes damage each round, and all of it lands on the enemy's front unit.
// That is what makes the Might proxy exact rather than approximate — attack sums
// because everyone fires, effective HP sums because only the front is hit — and
// it is also the only shape that animates legibly on a portrait phone.
func Simulate(cfg *gameconfig.Bundle, rng *rand.Rand, seed uint64, attacker, defender Army) *Replay {
	c := cfg.Soldiers.Combat

	rep := &Replay{
		Version: 1, Seed: seed, ConfigVersion: cfg.Version,
		Attacker: attacker, Defender: defender,
		Events: make([]Event, 0, 256),
	}

	// Home Ground: the defender fights with +8% defence. A small, legible thumb
	// on the scale that makes attacking a genuine decision rather than free.
	aUnits := buildSide(attacker, SideAttacker, 10000)
	dUnits := buildSide(defender, SideDefender, 10000+c.HomeGroundBP)
	if len(aUnits) == 0 || len(dUnits) == 0 {
		rep.Winner = SideDefender
		if len(dUnits) == 0 {
			rep.Winner = SideAttacker
		}
		return rep
	}

	// Fortune of War, rolled once per side before anything animates.
	//
	// This is the ONLY knob that can shape the win curve. With ~200 damage rolls
	// per side, per-hit noise averages away to a coefficient of variation under
	// 0.04, so crit and dodge cannot move it. A per-unit roll fails too: its
	// effect shrinks as 1/sqrt(N), so the curve would drift as players buy slots.
	rep.FortuneABP = rollFortune(rng, c)
	rep.FortuneDBP = rollFortune(rng, c)

	var aSpeed, dSpeed int64
	for _, u := range aUnits {
		aSpeed += u.Speed
	}
	for _, u := range dUnits {
		dSpeed += u.Speed
	}
	rep.FirstSide = SideAttacker
	if dSpeed > aSpeed {
		rep.FirstSide = SideDefender
	}
	fastSide := rep.FirstSide

	aFront, dFront := 0, 0

	for round := 1; round <= c.MaxRounds; round++ {
		rep.Rounds = round
		rageBP := 10000 + c.RageStepBP*int64(round-1)

		order := []Side{rep.FirstSide, other(rep.FirstSide)}
		for _, side := range order {
			var src, dst []*unit
			var frontIx *int
			if side == SideAttacker {
				src, dst, frontIx = aUnits, dUnits, &dFront
			} else {
				src, dst, frontIx = dUnits, aUnits, &aFront
			}

			fortune := rep.FortuneABP
			if side == SideDefender {
				fortune = rep.FortuneDBP
			}

			target := advanceFront(dst, frontIx)
			if target == nil {
				continue
			}

			var total int64
			for _, u := range src {
				if !u.alive() {
					continue
				}
				dmg, crit, dodged := strike(cfg, rng, u, target, fortune, rageBP, round, side == fastSide)
				if dodged {
					rep.Events = append(rep.Events, Event{Round: round, Kind: "dodge", Side: side, Src: u.ID, Dst: target.ID})
					continue
				}
				total += dmg
				rep.Events = append(rep.Events, Event{
					Round: round, Kind: "hit", Side: side, Src: u.ID, Dst: target.ID,
					Damage: dmg, Crit: crit,
				})
			}

			// Excess damage is wasted rather than carrying to the next unit. That
			// is what makes a deep line worth having.
			target.hp -= total
			if target.hp <= 0 {
				target.hp = 0
				rep.Events = append(rep.Events, Event{Round: round, Kind: "death", Side: other(side), Dst: target.ID})
			}
			rep.Events = append(rep.Events, Event{
				Round: round, Kind: "hp", Side: other(side), Dst: target.ID, HPLeft: target.hp,
			})

			if !anyAlive(dst) {
				rep.Winner = side
				return rep
			}
		}
	}

	// Timeout: whoever kept the larger fraction of their health. An exact tie
	// goes to the defender, so a stalemate never rewards the aggressor.
	rep.TimedOut = true
	aFrac := healthFraction(aUnits)
	dFrac := healthFraction(dUnits)
	rep.Winner = SideDefender
	if aFrac > dFrac {
		rep.Winner = SideAttacker
	}
	return rep
}

func buildSide(a Army, side Side, defScaleBP int64) []*unit {
	out := make([]*unit, 0, len(a.Units))
	for _, cbt := range a.Units {
		u := &unit{Combatant: cbt, side: side, hp: cbt.HP, maxHP: cbt.HP, level: a.Level}
		u.Defense = u.Defense * defScaleBP / 10000
		if u.hp <= 0 {
			continue
		}
		out = append(out, u)
	}
	// Fastest first, ties broken by id, so ordering is fully deterministic and an
	// audit re-run cannot disagree about who stood where.
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Speed != out[j].Speed {
			return out[i].Speed > out[j].Speed
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func advanceFront(units []*unit, front *int) *unit {
	for *front < len(units) {
		if units[*front].alive() {
			return units[*front]
		}
		*front++
	}
	return nil
}

func anyAlive(units []*unit) bool {
	for _, u := range units {
		if u.alive() {
			return true
		}
	}
	return false
}

func healthFraction(units []*unit) int64 {
	var hp, max int64
	for _, u := range units {
		if u.hp > 0 {
			hp += u.hp
		}
		max += u.maxHP
	}
	if max == 0 {
		return 0
	}
	return hp * 10000 / max
}

func other(s Side) Side {
	if s == SideAttacker {
		return SideDefender
	}
	return SideAttacker
}

// strike resolves one unit's contribution to a volley.
func strike(cfg *gameconfig.Bundle, rng *rand.Rand, u, target *unit, fortuneBP, rageBP int64, round int, isFastSide bool) (dmg int64, crit, dodged bool) {
	c := cfg.Soldiers.Combat

	if rng.Int64N(10000) < dodgeChanceBP(cfg, target, u) {
		return 0, false, true
	}

	v := c.DMGKBP
	base := u.Attack * v / 10000
	base = base * fortuneBP / 10000
	base = base * rageBP / 10000

	drBP := army.DamageReductionBP(cfg, target.Defense, target.level)
	base = base * (10000 - drBP) / 10000

	span := c.VarianceMaxBP - c.VarianceMinBP
	variance := c.VarianceMinBP
	if span > 0 {
		variance += rng.Int64N(span + 1)
	}
	base = base * variance / 10000

	if rng.Int64N(10000) < critChanceBP(cfg, u, target) {
		crit = true
		base = base * c.CritMultBP / 10000
	}
	// Charge: the faster side hits harder on round one only. The single most
	// legible payoff for investing in horses, and it animates as a cavalry charge.
	if round == 1 && isFastSide {
		base = base * (10000 + c.ChargeBonusBP) / 10000
	}

	if base < 1 {
		base = 1 // never a zero-damage hit; a stalled bar reads as a broken game
	}
	return base, crit, false
}

func critChanceBP(cfg *gameconfig.Bundle, u, target *unit) int64 {
	c := cfg.Soldiers.Combat
	denom := u.Speed + target.Speed + 1
	bp := c.CritBaseBP + c.CritSpeedBP*u.Speed/denom
	if bp > c.CritCapBP {
		return c.CritCapBP
	}
	return bp
}

func dodgeChanceBP(cfg *gameconfig.Bundle, target, attacker *unit) int64 {
	c := cfg.Soldiers.Combat
	denom := target.Speed + attacker.Speed + 1
	bp := c.DodgeSpeedBP * target.Speed / denom
	if bp > c.DodgeCapBP {
		return c.DodgeCapBP
	}
	return bp
}

// rollFortune draws a side's battle-long damage multiplier, in basis points.
//
// Log-normal, clamped at two sigma. The float is drawn once, immediately
// quantised to basis points and recorded in the replay; everything downstream is
// integer, and an audit re-run reads the recorded value rather than re-drawing.
func rollFortune(rng *rand.Rand, c gameconfig.CombatConfig) int64 {
	sigma := float64(c.FortuneSigmaBP) / 10000.0
	clamp := float64(c.FortuneClampSigmas) * sigma

	f := rng.NormFloat64() * sigma
	if f > clamp {
		f = clamp
	} else if f < -clamp {
		f = -clamp
	}
	return int64(math.Round(math.Exp(f) * 10000))
}
