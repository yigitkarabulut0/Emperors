package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/frenzy"
)

// The Golden Hour (retention.frenzy): keep collecting, no gap longer than the
// window, until the run has spent its share of the pool, and it lights for a
// minute in which collects pay double gold on up to a share of the pool's
// energy. The bonus rides the collect bucket's TIMED lane (economy.AddTemp),
// so ApplyBucket applies it once, under that lane's ceiling. Gold only: it
// never moves the climb.

// FrenzyView is the Golden Hour on the snapshot: Collect's hourglass wheel.
type FrenzyView struct {
	Unlocked    bool    `json:"unlocked"`
	UnlockLevel int     `json:"unlock_level"`
	Meter       float64 `json:"meter"`
	Active      bool    `json:"active"`
	EndsIn      int64   `json:"ends_in"`
	EnergyLeft  int64   `json:"energy_left"`
	Used        int     `json:"used"`
	PerDay      int     `json:"per_day"`
	ReadyIn     int64   `json:"ready_in"`
	Window      int64   `json:"window"`
	BP          int64   `json:"bp"`
	Duration    int64   `json:"duration"`
	DrainsIn    int64   `json:"drains_in"`
	Cooldown    int64   `json:"cooldown"`
}

func frenzyState(p sqlcdb.AppPlayer) frenzy.State {
	s := frenzy.State{MeterMilli: p.FrenzyMeterMilli, EnergyLeft: p.FrenzyEnergyLeft, Used: int(p.FrenzyUsed)}
	if p.FrenzyLastAt != nil {
		s.LastAt = *p.FrenzyLastAt
	}
	if p.FrenzyUntil != nil {
		s.Until = *p.FrenzyUntil
	}
	if p.FrenzyReadyAt != nil {
		s.ReadyAt = *p.FrenzyReadyAt
	}
	if p.FrenzyDay.Valid {
		s.Day = localDay(p.FrenzyDay.Time.UTC(), 0)
	}
	return s
}

func (d Deps) frenzyView(p sqlcdb.AppPlayer, maxEnergy int64, now time.Time) FrenzyView {
	r := d.Config.Retention.Frenzy
	v := frenzy.Read(frenzyState(p), r, maxEnergy, now, localDay(now, p.ResetOffsetMinutes))
	return FrenzyView{
		Unlocked: int(p.Level) >= r.UnlockLevel, UnlockLevel: r.UnlockLevel,
		Meter: v.Meter, Active: v.Active, EndsIn: v.EndsIn, EnergyLeft: v.EnergyLeft,
		Used: v.Used, PerDay: r.PerDay, ReadyIn: v.ReadyIn, Window: r.WindowSeconds,
		BP: r.BonusBP, Duration: r.DurationSeconds, DrainsIn: v.DrainsIn, Cooldown: r.CooldownSeconds,
	}
}

// frenzyRun carries the Golden Hour through the collects of one action.
type frenzyRun struct {
	state   frenzy.State
	today   time.Time
	gold    int64 // what it added
	started bool
	changed bool
}

func (d Deps) newFrenzyRun(p sqlcdb.AppPlayer, now time.Time) *frenzyRun {
	return &frenzyRun{state: frenzyState(p), today: localDay(now, p.ResetOffsetMinutes)}
}

// collect is one collect of job's cost at now: the bonuses its gold is paid
// with (the lord's own, plus the Golden Hour's in the timed lane when this
// collect is covered) and whether it is covered.
func (d Deps) frenzyBonuses(f *frenzyRun, bonuses economy.Bonuses, cost, maxEnergy int64, level int,
	now time.Time) (economy.Bonuses, bool) {
	r := d.Config.Retention.Frenzy
	next, covered, started := frenzy.Step(f.state, r, cost, maxEnergy, level, now, f.today)
	f.state, f.changed = next, true
	if started {
		f.started = true
	}
	if !covered {
		return bonuses, false
	}
	boosted := bonuses
	boosted.AddTemp(economy.BucketCollectIncome, r.BonusBP)
	return boosted, true
}

// save writes the Golden Hour's state back, in the action's transaction.
func (f *frenzyRun) save(ctx context.Context, q *sqlcdb.Queries, id sqlcdb.AppPlayer) error {
	if !f.changed {
		return nil
	}
	s := f.state
	at := func(t time.Time) *time.Time {
		if t.IsZero() {
			return nil
		}
		v := t.Truncate(time.Microsecond)
		return &v
	}
	day := pgtype.Date{}
	if !s.Day.IsZero() {
		day = pgtype.Date{Time: s.Day, Valid: true}
	}
	if err := q.SetFrenzy(ctx, sqlcdb.SetFrenzyParams{
		ID: id.ID, MeterMilli: s.MeterMilli, LastAt: at(s.LastAt), Until: at(s.Until),
		EnergyLeft: s.EnergyLeft, Day: day, Used: int16(s.Used), ReadyAt: at(s.ReadyAt),
	}); err != nil {
		return fmt.Errorf("golden hour: %w", err)
	}
	return nil
}
