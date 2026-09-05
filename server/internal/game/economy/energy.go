package economy

import (
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// MilliPerEnergy is the fixed-point scale for stored energy. Energy is kept in
// thousandths so a regen rate that does not divide evenly into a second is not
// silently rounded away on every settle.
const MilliPerEnergy = 1000

// EnergyState is the stored representation. There is no "current energy"
// column: energy is (value, anchor) and is materialised on read, so nothing
// sweeps every player every minute.
type EnergyState struct {
	Milli     int64
	UpdatedAt time.Time
}

// MaxEnergy is the player's energy ceiling.
//
// Note what this does NOT affect: the regeneration rate. Max Energy is a "how
// long can I be away" stat; regen speed is a "how much do I earn per day" stat.
// Keeping them separate is what stops a player from buying unbounded income.
//
// The level term exists because a pool that never grows makes the regen rate
// irrelevant to anybody who is not checking in more often than it takes to fill.
// With a 60-point pool at one a minute, a player with three sessions a day
// captured 180 energy a day, and halving the regen period changed that number by
// exactly zero -- the pool filled in half an hour and then stopped. Growing the
// ceiling with level is what makes regen speed mean anything again.
func MaxEnergy(cfg *gameconfig.Bundle, level int64, statEnergy int64, flatBonus int64) int64 {
	e := cfg.Progression.Energy
	if level < 1 {
		level = 1
	}
	m := e.BaseMax + e.PerLevel*(level-1) + e.PerStatPoint*statEnergy + flatBonus
	if m < 1 {
		return 1
	}
	return m
}

// RegenPeriodMillis returns milliseconds per 1 energy.
//
// Expressed as a PERIOD rather than a rate so it stays exact in integer
// arithmetic: a rate in energy-per-second would need a float or would round to
// zero for slow regen.
func RegenPeriodMillis(cfg *gameconfig.Bundle, bonuses Bonuses) int64 {
	base := cfg.Progression.Energy.RegenBaseSeconds * 1000
	bp := EffectiveBP(bonuses, BucketEnergyRegen)
	period := base * 10000 / (10000 + bp)
	if period < 1 {
		return 1
	}
	return period
}

// Settle advances energy to `now` and returns the new state.
//
// Two details that matter:
//
//   - The anchor advances by the time actually CONSUMED, not to `now`. Integer
//     division drops the sub-period remainder; if the anchor jumped to `now`
//     every time, a player whose client polls often would leak energy on every
//     call and regenerate measurably slower than one who polls rarely.
//   - There is no overflow. Regen stops hard at max, which is the intended
//     pressure to log in several times a day, and the reason Max Energy has
//     value at all. When clamped, the anchor does move to `now`: the excess is
//     deliberately discarded, not banked.
//
// Settle is idempotent for a given `now`, and monotonic: calling it twice with
// the same timestamp changes nothing.
func Settle(s EnergyState, maxEnergy int64, periodMillis int64, now time.Time) EnergyState {
	maxMilli := maxEnergy * MilliPerEnergy

	// A clock that went backwards (NTP correction, a bad caller) must never
	// destroy energy. Re-anchor and leave the value alone.
	elapsed := now.Sub(s.UpdatedAt).Milliseconds()
	if elapsed <= 0 {
		return EnergyState{Milli: min64(s.Milli, maxMilli), UpdatedAt: s.UpdatedAt}
	}

	if s.Milli >= maxMilli {
		// Already full: nothing accrues, but the anchor must move or the player
		// would bank the whole idle period the instant they spend.
		return EnergyState{Milli: maxMilli, UpdatedAt: now}
	}

	gain := elapsed * MilliPerEnergy / periodMillis
	if gain <= 0 {
		// Not even a thousandth of a point yet — leave the anchor so the partial
		// interval keeps accumulating.
		return s
	}

	next := s.Milli + gain
	if next >= maxMilli {
		return EnergyState{Milli: maxMilli, UpdatedAt: now}
	}

	consumed := gain * periodMillis / MilliPerEnergy
	return EnergyState{Milli: next, UpdatedAt: s.UpdatedAt.Add(time.Duration(consumed) * time.Millisecond)}
}

// Spend deducts whole energy points. It reports false without mutating when the
// player cannot afford it.
func Spend(s EnergyState, points int64) (EnergyState, bool) {
	cost := points * MilliPerEnergy
	if cost < 0 || s.Milli < cost {
		return s, false
	}
	return EnergyState{Milli: s.Milli - cost, UpdatedAt: s.UpdatedAt}, true
}

// Whole returns the usable (floored) energy points.
func Whole(s EnergyState) int64 { return s.Milli / MilliPerEnergy }

// Refill sets energy to full — used on level-up.
func Refill(maxEnergy int64, now time.Time) EnergyState {
	return EnergyState{Milli: maxEnergy * MilliPerEnergy, UpdatedAt: now}
}

// SecondsUntilFull is what the client renders as the "full in 1h 12m" label.
func SecondsUntilFull(s EnergyState, maxEnergy, periodMillis int64) int64 {
	missing := maxEnergy*MilliPerEnergy - s.Milli
	if missing <= 0 {
		return 0
	}
	return (missing*periodMillis/MilliPerEnergy + 999) / 1000
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
