package frenzy

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var rules = gameconfig.FrenzyConfig{UnlockLevel: 5, WindowSeconds: 20, FillPct: 40, DurationSeconds: 60,
	BonusBP: 10000, CoverPct: 30, PerDay: 3, CooldownSeconds: 1800}

var (
	day = time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	t0  = day.Add(10 * time.Hour)
)

// A steady run fills the meter and lights the Golden Hour; the collects after
// it are covered until the energy it covers is spent.
func TestASteadyRunLightsTheGoldenHour(t *testing.T) {
	const max = 200 // needs 80 energy; covers 60
	s := State{}
	now := t0
	lit := -1
	for i := 0; i < 8; i++ { // 10 energy a collect, 5 s apart
		var covered, started bool
		s, covered, started = Step(s, rules, 10, max, 10, now, day)
		if covered {
			t.Fatalf("collect %d was covered before the hour was lit", i)
		}
		if started {
			lit = i
		}
		now = now.Add(5 * time.Second)
	}
	if lit != 7 || s.Used != 1 || s.EnergyLeft != 60 {
		t.Fatalf("lit on collect %d, used %d, covering %d; want 7, 1, 60", lit, s.Used, s.EnergyLeft)
	}
	covered := 0
	for i := 0; i < 10; i++ {
		var c bool
		s, c, _ = Step(s, rules, 10, max, 10, now, day)
		if c {
			covered++
		}
		now = now.Add(2 * time.Second)
	}
	if covered != 6 {
		t.Fatalf("%d collects covered, want the 60 energy's six", covered)
	}
}

// A gap longer than the window empties the meter; the cooldown and the day's
// three keep it from lighting again at once; a new day gives three more.
func TestTheMeterDrainsAndTheHourRests(t *testing.T) {
	const max = 100 // needs 40 energy
	s, _, _ := Step(State{}, rules, 30, max, 10, t0, day)
	s, _, started := Step(s, rules, 30, max, 10, t0.Add(25*time.Second), day)
	if started || s.MeterMilli != 30000 {
		t.Fatalf("after a 25 s gap the run should start over: meter %d started %v", s.MeterMilli, started)
	}
	if v := Read(s, rules, max, t0.Add(30*time.Second), day); v.Meter <= 0.7 || v.Meter >= 0.8 || v.DrainsIn != 15 {
		t.Fatalf("the meter at 5 s: %+v", v)
	}
	if v := Read(s, rules, max, t0.Add(50*time.Second), day); v.Meter != 0 || v.DrainsIn != 0 {
		t.Fatalf("the meter after the window: %+v", v)
	}

	s = State{Day: day, Used: 1, ReadyAt: t0.Add(time.Hour)}
	s, _, started = Step(s, rules, 50, max, 10, t0, day)
	if started || s.MeterMilli != 40000 {
		t.Fatalf("lit inside the cooldown: %+v", s)
	}
	s = State{Day: day, Used: 3}
	if _, _, started := Step(s, rules, 50, max, 10, t0, day); started {
		t.Fatal("a fourth Golden Hour in one day")
	}
	if _, _, started := Step(s, rules, 50, max, 10, t0, day.AddDate(0, 0, 1)); !started {
		t.Fatal("a new day should light again")
	}
	if _, _, started := Step(State{}, rules, 50, max, 4, t0, day); started {
		t.Fatal("lit below its level")
	}
}
