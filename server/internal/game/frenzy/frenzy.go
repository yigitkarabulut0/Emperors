// Package frenzy is the Golden Hour: a run of collects that fills a meter, and
// the minute of doubled gold it lights.
//
// Pure: the service keeps the state on the player row and applies the bonus
// through economy.AddTemp and ApplyBucket like every other timed bonus. This
// package only says which collects it covers.
package frenzy

import (
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// State is what the player row keeps.
type State struct {
	// Energy spent in the current run, in milli-energy.
	MeterMilli int64
	// The last collect that counted toward the run.
	LastAt time.Time
	// While the Golden Hour burns: its end, and the energy it may still cover.
	Until      time.Time
	EnergyLeft int64
	// Golden Hours lit on Day (the lord's local date), and when the next may.
	Day     time.Time
	Used    int
	ReadyAt time.Time
}

// Step is one collect of cost energy at now, for a lord with this pool and at
// this level. It returns the state after, whether this collect is paid the
// Golden Hour's bonus, and whether it lit the Golden Hour.
//
// A collect inside a burning Golden Hour is covered while energy is left, and
// does not fill the meter. Otherwise it fills the meter -- a gap longer than
// the window empties it first -- and a full meter lights the Golden Hour when
// the day has one left and the cooldown has passed. The collect that lights it
// is not itself covered: the next ones are.
func Step(s State, r gameconfig.FrenzyConfig, cost, maxEnergy int64, level int, now, today time.Time) (State, bool, bool) {
	if !s.Day.Equal(today) {
		s.Day, s.Used = today, 0
	}
	if level < r.UnlockLevel || cost <= 0 {
		return s, false, false
	}
	if now.Before(s.Until) && s.EnergyLeft > 0 {
		s.EnergyLeft -= cost
		if s.EnergyLeft <= 0 {
			s.EnergyLeft = 0
			s.Until = now
		}
		return s, true, false
	}

	window := time.Duration(r.WindowSeconds) * time.Second
	if s.LastAt.IsZero() || now.Sub(s.LastAt) > window {
		s.MeterMilli = 0
	}
	need := Need(r, maxEnergy)
	s.MeterMilli += cost * 1000
	if s.MeterMilli > need {
		s.MeterMilli = need
	}
	s.LastAt = now
	if s.MeterMilli < need || s.Used >= r.PerDay || now.Before(s.ReadyAt) {
		return s, false, false
	}
	dur := time.Duration(r.DurationSeconds) * time.Second
	s.Until = now.Add(dur)
	s.EnergyLeft = maxEnergy * r.CoverPct / 100
	if s.EnergyLeft < 1 {
		s.EnergyLeft = 1
	}
	s.Used++
	s.ReadyAt = s.Until.Add(time.Duration(r.CooldownSeconds) * time.Second)
	s.MeterMilli = 0
	return s, false, true
}

// Need is the milli-energy a run must spend to light the Golden Hour.
func Need(r gameconfig.FrenzyConfig, maxEnergy int64) int64 {
	n := maxEnergy * r.FillPct * 10 // maxEnergy * FillPct/100 * 1000
	if n < 1000 {
		n = 1000
	}
	return n
}

// View is the Golden Hour as the screen shows it at now.
type View struct {
	Meter      float64 // 0..1 of the fill a run needs; 0 once the window passes
	Active     bool
	EndsIn     int64 // whole seconds
	EnergyLeft int64
	Used       int
	ReadyIn    int64 // whole seconds until another may light
	DrainsIn   int64 // whole seconds until the meter empties without a collect
}

// Read is the Golden Hour at now.
func Read(s State, r gameconfig.FrenzyConfig, maxEnergy int64, now, today time.Time) View {
	v := View{Used: s.Used}
	if !s.Day.Equal(today) {
		v.Used = 0
	}
	if now.Before(s.Until) && s.EnergyLeft > 0 {
		v.Active = true
		v.EndsIn = ceilSeconds(s.Until.Sub(now))
		v.EnergyLeft = s.EnergyLeft
	}
	if now.Before(s.ReadyAt) {
		v.ReadyIn = ceilSeconds(s.ReadyAt.Sub(now))
	}
	window := time.Duration(r.WindowSeconds) * time.Second
	if !v.Active && s.MeterMilli > 0 && !s.LastAt.IsZero() && now.Sub(s.LastAt) <= window {
		v.Meter = float64(s.MeterMilli) / float64(Need(r, maxEnergy))
		if v.Meter > 1 {
			v.Meter = 1
		}
		v.DrainsIn = ceilSeconds(s.LastAt.Add(window).Sub(now))
	}
	return v
}

func ceilSeconds(d time.Duration) int64 {
	if d <= 0 {
		return 0
	}
	return int64((d + time.Second - 1) / time.Second)
}
