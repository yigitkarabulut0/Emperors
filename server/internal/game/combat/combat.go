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
	// The art key of the weapon this unit fights with, for the screen to swing.
	// A battle is watched, and what a player wants to see swing is the sword
	// they bought. Empty for a soldier, and for a hero with an empty hand.
	Weapon  string `json:"weapon,omitempty"`
	Attack  int64  `json:"attack"`
	Defense int64  `json:"defense"`
	Speed   int64  `json:"speed"`
	HP      int64  `json:"hp"`
}

// Army is one side's frozen roster.
type Army struct {
	PlayerID string      `json:"player_id"`
	Name     string      `json:"name"`
	Avatar   string      `json:"avatar"`
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
	Version       int    `json:"v"`
	Seed          uint64 `json:"seed"`
	ConfigVersion int    `json:"balance_version"`
	FortuneABP    int64  `json:"fortune_a_bp"`
	FortuneDBP    int64  `json:"fortune_d_bp"`
	FirstSide     Side   `json:"order"`
	Rounds        int    `json:"rounds"`
	Winner        Side   `json:"winner"`
	TimedOut      bool   `json:"timed_out"`
	Attacker      Army   `json:"attacker"`
	Defender      Army   `json:"defender"`

	// Carried in the replay so it stays self-contained: a replay re-watched a
	// week later must show what the armies were worth at the time, not now.
	AttackerMight int64 `json:"attacker_might"`
	DefenderMight int64 `json:"defender_might"`

	// What each side had left of its health when it ended, in basis points.
	//
	// The campaign's stars are read off the attacker's: a win is one, half the
	// health left is two, more is three. It is recorded rather than recomputed
	// from the event log, because the log is what the CLIENT animates and the
	// stars are a number the server owes the player before the animation runs.
	AttackerHPLeftBP int64 `json:"attacker_hp_left_bp"`
	DefenderHPLeftBP int64 `json:"defender_hp_left_bp"`

	// What each side actually DEALT, in hit points, summed as the blows landed.
	//
	// The kingdom's boss is why this is a number and not a fraction. A beast
	// with fifty million health takes a few thousand from one lord's blow, and
	// that is 4 basis points of its bar: a damage read off a fraction would
	// round a lord's whole afternoon to nothing. The pool a blow digs out of the
	// beast is this figure, exactly, and the damage list is built from it.
	AttackerDamage int64 `json:"attacker_damage"`
	DefenderDamage int64 `json:"defender_damage"`

	Events []Event `json:"events"`
}

// Options are the knobs a fight that is not an ordinary raid may turn.
//
// The zero value IS an ordinary raid: Simulate is SimulateWith with no options
// at all, and options_test.go holds the two byte-identical over two thousand
// seeds. Anything that wants a different fight turns a knob here rather than
// growing a second simulator -- there is one battle in this game, and every
// screen that shows one is showing this function's work.
type Options struct {
	// What the defender's own ground is worth, in basis points added to their
	// defence. Nil is the balance's Home Ground.
	HomeGroundBP *int64
	// The most rounds the fight may run before the timeout rule decides it.
	// Nil is the balance's.
	MaxRounds *int
}

// Champion is a side as it fights: one figure carrying the whole army.
//
// A raid is the player's hero leading their soldiers, not ten separate duels,
// and this is what the screen shows -- two champions trading single blows, the
// way Shakes & Fidget does it. The arithmetic is the same as the roster it
// replaces, on purpose:
//
//   Attack is the sum, because in the old model every unit struck once a round,
//   so a side dealt the sum of its attacks per round. It still does, in one blow
//   instead of ten.
//
//   HP is the sum, and the damage reduction is chosen so the champion takes
//   exactly as much punishment as the roster did. Killing a roster costs the sum
//   of its EFFECTIVE hit points -- hp scaled up by each unit's own reduction --
//   because only the front rank was ever hit. So the champion's reduction is set
//   from that: hp_total / ehp_total is what survives the armour.
//
//   Speed is the sum, so crit and dodge still turn on the ratio of one army's
//   speed to the other's.
//
// Might is sqrt(attack x ehp), and both are carried over exactly, so the win
// curve the calibration test guards does not move.
type Champion struct {
	Combatant
	side  Side
	hp    int64
	maxHP int64
	level int64
	drBP  int64 // what its armour takes off every blow, in basis points
}

func (c *Champion) alive() bool { return c.hp > 0 }

// Simulate runs a battle to completion.
//
// Two champions, the attacker first, one blow each per round until one falls or
// the rounds run out.
//
// It used to be a roster of up to ten units a side acting one at a time in speed
// order, each with its own hit points and its own armour. That animated as a
// stream of small numbers over a row of portraits -- legible as data, not as a
// fight -- and it made a raid look like a spreadsheet settling. The maths is
// carried over intact (see Champion); what changed is that a side's whole
// strength lands in one readable blow.
func Simulate(cfg *gameconfig.Bundle, rng *rand.Rand, seed uint64, attacker, defender Army) *Replay {
	return SimulateWith(cfg, rng, seed, attacker, defender, Options{})
}

// SimulateWith is Simulate with the knobs turned. See Options.
func SimulateWith(cfg *gameconfig.Bundle, rng *rand.Rand, seed uint64, attacker, defender Army, opts Options) *Replay {
	c := cfg.Soldiers.Combat
	homeGroundBP := c.HomeGroundBP
	if opts.HomeGroundBP != nil {
		homeGroundBP = *opts.HomeGroundBP
	}
	maxRounds := c.MaxRounds
	if opts.MaxRounds != nil {
		maxRounds = *opts.MaxRounds
	}

	rep := &Replay{
		Version: 2, Seed: seed, ConfigVersion: cfg.Version,
		Attacker: attacker, Defender: defender,
		Events: make([]Event, 0, 64),
	}

	// Home Ground: the defender fights with +8% defence. A small, legible thumb
	// on the scale that makes attacking a genuine decision rather than free.
	a := buildChampion(cfg, attacker, SideAttacker, 10000)
	d := buildChampion(cfg, defender, SideDefender, 10000+homeGroundBP)
	if a == nil || d == nil {
		rep.Winner = SideDefender
		if d == nil {
			rep.Winner = SideAttacker
			rep.AttackerHPLeftBP = 10000
		} else {
			rep.DefenderHPLeftBP = 10000
		}
		return rep
	}

	// Fortune of War, rolled once per side before anything animates.
	//
	// This is the ONLY knob that can shape the win curve. Per-blow noise cannot:
	// it averages away over a battle, and a per-unit roll would shrink as
	// 1/sqrt(N) and drift as players buy slots.
	rep.FortuneABP = rollFortune(rng, c)
	rep.FortuneDBP = rollFortune(rng, c)

	// The attacker always opens: the player who chose to raid should see their
	// own blow land first. The charge still belongs to the genuinely faster
	// army, which is a separate question from who is raiding whom.
	rep.FirstSide = SideAttacker
	fastSide := SideAttacker
	if d.Speed > a.Speed {
		fastSide = SideDefender
	}

	for round := 1; round <= maxRounds; round++ {
		rep.Rounds = round
		rageBP := 10000 + c.RageStepBP*int64(round-1)
		rep.Events = append(rep.Events, Event{Round: round, Kind: "round"})

		for _, turn := range [2]*Champion{a, d} {
			foe := d
			fortune := rep.FortuneABP
			if turn.side == SideDefender {
				foe = a
				fortune = rep.FortuneDBP
			}
			if !turn.alive() {
				continue
			}

			dmg, crit, dodged := blow(cfg, rng, turn, foe, fortune, rageBP, round,
				turn.side == fastSide)
			if dodged {
				rep.Events = append(rep.Events, Event{
					Round: round, Kind: "dodge", Side: turn.side, Src: turn.ID, Dst: foe.ID})
				continue
			}
			rep.Events = append(rep.Events, Event{
				Round: round, Kind: "hit", Side: turn.side, Src: turn.ID, Dst: foe.ID,
				Damage: dmg, Crit: crit,
			})
			// What the blow was worth, before the foe's own floor takes it: a
			// beast with more health than the blow can reach still loses
			// exactly this much of it.
			if turn.side == SideAttacker {
				rep.AttackerDamage += dmg
			} else {
				rep.DefenderDamage += dmg
			}
			foe.hp -= dmg
			if foe.hp < 0 {
				foe.hp = 0
			}
			rep.Events = append(rep.Events, Event{
				Round: round, Kind: "hp", Side: foe.side, Dst: foe.ID, HPLeft: foe.hp})
			if !foe.alive() {
				rep.Events = append(rep.Events, Event{
					Round: round, Kind: "death", Side: foe.side, Dst: foe.ID})
				rep.Winner = turn.side
				recordHealth(rep, a, d)
				return rep
			}
		}
	}

	// Timeout: whoever kept the larger fraction of their health. An exact tie
	// goes to the defender, so a stalemate never rewards the aggressor.
	rep.TimedOut = true
	recordHealth(rep, a, d)
	rep.Winner = SideDefender
	if rep.AttackerHPLeftBP > rep.DefenderHPLeftBP {
		rep.Winner = SideAttacker
	}
	return rep
}

// recordHealth writes down what each side had left when the fight ended.
func recordHealth(rep *Replay, a, d *Champion) {
	rep.AttackerHPLeftBP = a.hp * 10000 / max64(a.maxHP, 1)
	rep.DefenderHPLeftBP = d.hp * 10000 / max64(d.maxHP, 1)
}

// buildChampion folds a roster into the one figure that fights for it.
func buildChampion(cfg *gameconfig.Bundle, roster Army, side Side, defScaleBP int64) *Champion {
	var atk, spd, hp, ehp int64
	var face Combatant
	var haveFace bool
	for _, u := range roster.Units {
		if u.HP <= 0 {
			continue
		}
		def := u.Defense * defScaleBP / 10000
		drBP := army.DamageReductionBP(cfg, def, roster.Level)
		atk += u.Attack
		spd += u.Speed
		hp += u.HP
		// What it costs to kill this unit through its own armour.
		ehp += u.HP * 10000 / max64(10000-drBP, 1)
		// The hero is the face of the army; failing that, the first unit in it.
		if u.IsHero || !haveFace {
			if u.IsHero || !face.IsHero {
				face = u
				haveFace = true
			}
		}
	}
	if hp <= 0 {
		return nil
	}
	return &Champion{
		Combatant: Combatant{
			ID: roster.PlayerID, Name: roster.Name, Tier: face.Tier, Type: face.Type,
			IsHero: true, Weapon: face.Weapon,
			Attack: atk, Defense: face.Defense, Speed: spd, HP: hp,
		},
		side: side, hp: hp, maxHP: hp, level: roster.Level,
		// Set so that hp / (1 - dr) == ehp: the champion takes exactly the
		// punishment the roster it replaces would have taken.
		drBP: 10000 - hp*10000/max64(ehp, 1),
	}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func other(s Side) Side {
	if s == SideAttacker {
		return SideDefender
	}
	return SideAttacker
}

// blow resolves one champion's swing at the other.
func blow(cfg *gameconfig.Bundle, rng *rand.Rand, u, target *Champion, fortuneBP, rageBP int64, round int, isFastSide bool) (dmg int64, crit, dodged bool) {
	c := cfg.Soldiers.Combat

	if rng.Int64N(10000) < dodgeChanceBP(cfg, target, u) {
		return 0, false, true
	}

	v := c.DMGKBP
	base := u.Attack * v / 10000
	base = base * fortuneBP / 10000
	base = base * rageBP / 10000

	// The champion's own reduction, set when it was folded together so that it
	// absorbs exactly what its roster would have.
	base = base * (10000 - target.drBP) / 10000

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

func critChanceBP(cfg *gameconfig.Bundle, u, target *Champion) int64 {
	c := cfg.Soldiers.Combat
	denom := u.Speed + target.Speed + 1
	bp := c.CritBaseBP + c.CritSpeedBP*u.Speed/denom
	if bp > c.CritCapBP {
		return c.CritCapBP
	}
	return bp
}

func dodgeChanceBP(cfg *gameconfig.Bundle, target, attacker *Champion) int64 {
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
	clamp := float64(c.FortuneClampSigmasX10) / 10.0 * sigma

	f := rng.NormFloat64() * sigma
	if f > clamp {
		f = clamp
	} else if f < -clamp {
		f = -clamp
	}
	return int64(math.Round(math.Exp(f) * 10000))
}
