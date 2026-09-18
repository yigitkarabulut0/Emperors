package service

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Boosts holds the server-wide modifiers in force, and swaps them atomically.
//
// Read on a POLL, never per request. loadEffects runs on every authenticated
// call, and a query there would put a database round trip in front of every
// action in the game to fetch a table that changes a few times a month. This is
// the same shape gameconfig.Store uses for published balance, for the same
// reason, and it fails the same way: if a refresh errors the previous snapshot
// stays live, because serving slightly stale boosts is better than serving none.
type Boosts struct {
	pool *pgxpool.Pool
	log  *slog.Logger
	now  func() time.Time

	// bucket -> basis points, summed across every live boost.
	current atomic.Pointer[map[string]int64]
	// The same, with when each bucket's first boost ends, and what is scheduled
	// to start within a day: what the game shows (LiveView).
	shown atomic.Pointer[ServerEvents]

	// The live-ops calendar, read on the same poll (liveops.go): each hour's
	// event as the table has it written down (rolled, forced or skipped), and
	// the festivals running or scheduled within a week.
	hourly    atomic.Pointer[map[int64]string]
	festivals atomic.Pointer[[]Festival]
	// The Throne's edict, read on the same poll (throne.go). Nil is "no decree
	// in force", which is also what a hand-built Deps sees: a test or a tool
	// with no poll feels no decree, exactly as it feels no festival.
	decree atomic.Pointer[Decree]
}

// ServerEvents is what an operator has running, and about to run.
type ServerEvents struct {
	Live     []ServerEvent
	Upcoming []ServerEvent
}

// ServerEvent is one bucket's boost: its basis points and its window.
type ServerEvent struct {
	Bucket   string
	BP       int64
	StartsAt time.Time
	EndsAt   time.Time
}

// upcomingWindow is how far ahead a scheduled boost is announced.
const upcomingWindow = 24 * time.Hour

// NewBoosts starts empty, which is exactly "no event running".
func NewBoosts(pool *pgxpool.Pool, log *slog.Logger, now func() time.Time) *Boosts {
	b := &Boosts{pool: pool, log: log, now: now}
	empty := map[string]int64{}
	b.current.Store(&empty)
	b.shown.Store(&ServerEvents{})
	hours := map[int64]string{}
	b.hourly.Store(&hours)
	b.festivals.Store(&[]Festival{})
	return b
}

// HourlyRows returns each hour's event as written down, around now. Never nil.
func (b *Boosts) HourlyRows() map[int64]string {
	if b == nil {
		return nil
	}
	return *b.hourly.Load()
}

// Decree is the reign's edict in force, as the last poll saw it. Nil safe: a
// Deps with no Boosts feels nothing.
func (b *Boosts) Decree() *Decree {
	if b == nil {
		return nil
	}
	return b.decree.Load()
}

// Festivals returns the festivals running or scheduled within a week, soonest
// first. Never nil.
func (b *Boosts) Festivals() []Festival {
	if b == nil {
		return nil
	}
	return *b.festivals.Load()
}

// Events returns what is running and about to. Never nil.
func (b *Boosts) Events() ServerEvents {
	if b == nil {
		return ServerEvents{}
	}
	return *b.shown.Load()
}

// Get returns the live modifiers. Never nil.
func (b *Boosts) Get() map[string]int64 {
	if b == nil {
		return nil
	}
	return *b.current.Load()
}

// Refresh reloads what is in force at this instant.
//
// A boost's window is evaluated HERE rather than in the effect path, so one
// starting or ending is picked up by the next poll instead of needing a sweeper
// -- and there is no moment where an expired boost is still applied because
// nothing ran.
func (b *Boosts) Refresh(ctx context.Context) error {
	now := b.now()
	q := sqlcdb.New(b.pool)
	rows, err := q.ActiveBoosts(ctx, now)
	if err != nil {
		return err
	}
	soon, err := q.UpcomingBoosts(ctx, sqlcdb.UpcomingBoostsParams{Now: now, Until: now.Add(upcomingWindow)})
	if err != nil {
		return err
	}
	next := make(map[string]int64, len(rows))
	ev := ServerEvents{Live: []ServerEvent{}, Upcoming: []ServerEvent{}}
	for _, r := range rows {
		next[r.Bucket] += r.AmountBp
		ev.Live = append(ev.Live, ServerEvent{Bucket: r.Bucket, BP: r.AmountBp, EndsAt: r.EndsAt})
	}
	for _, r := range soon {
		ev.Upcoming = append(ev.Upcoming, ServerEvent{Bucket: r.Bucket, BP: r.AmountBp, StartsAt: r.StartsAt, EndsAt: r.EndsAt})
	}
	b.current.Store(&next)
	b.shown.Store(&ev)

	// The hours the roll's no-repeat chain can reach back to, and the two ahead
	// the panel may already have set.
	h := liveops.Hour(now)
	hrows, err := q.ListHourlyEvents(ctx, sqlcdb.ListHourlyEventsParams{
		FromHour: h - hourlyLookback - 1, ToHour: h + hourlyLookahead,
	})
	if err != nil {
		return err
	}
	hours := make(map[int64]string, len(hrows))
	for _, r := range hrows {
		hours[r.Hour] = r.EventID
	}
	b.hourly.Store(&hours)

	frows, err := q.CurrentEvents(ctx, sqlcdb.CurrentEventsParams{Now: now, Until: now.Add(festivalWindow)})
	if err != nil {
		return err
	}
	fs := make([]Festival, 0, len(frows))
	for _, r := range frows {
		f, err := festivalOf(r)
		if err != nil {
			// A row that will not read is left out, never served half-read.
			b.log.Warn("festival does not read", "id", r.ID, "err", err)
			continue
		}
		fs = append(fs, f)
	}
	b.festivals.Store(&fs)

	// The Throne's edict. Read here rather than per request for the reason at
	// the top of this file: loadEffects runs on every authenticated call.
	if row, err := q.ActiveDecree(ctx, now); err == nil {
		b.decree.Store(&Decree{
			UWeek: row.Uweek, KingdomID: row.KingdomID, KingdomName: row.KingdomName,
			EmperorID: row.EmperorID, EmperorName: row.EmperorName,
			ID: derefStr(row.DecreeID), EndsAt: derefTime(row.DecreeEnds),
		})
	} else {
		b.decree.Store(nil)
	}
	return nil
}

// Poll keeps the snapshot fresh until the context is cancelled.
func (b *Boosts) Poll(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := b.Refresh(ctx); err != nil {
				b.log.Warn("could not refresh server boosts", "err", err)
			}
		}
	}
}

// BoostableBuckets are the buckets an operator may run an event on.
//
// Energy regeneration is deliberately absent. It is the single ceiling that
// bounds the entire gold supply -- max energy decides how long you can be away,
// regen decides how much you can earn in a day -- so a "double energy weekend"
// is not a generous event, it is an uncapped mint. If that is ever wanted it
// should be a balance publish, which is reviewed, versioned and rollback-able.
// Estate income is absent for a subtler reason than energy regen, and one worth
// writing down because it was shipped before it was caught: tax_milli_per_hour
// is a CACHED rate on the player row. The storehouse fills from that cache
// without recomputing effects, and the cache is only rewritten when the player
// next reads their state -- so a boost persisted into it, and once the event
// ended nothing refreshed it for anyone who was offline. Somebody who logged in
// during a boosted hour and returned a week later would have been filled at the
// boosted rate for the whole week.
var BoostableBuckets = []string{
	gameconfig.BucketCollectIncome,
	gameconfig.BucketXP,
	gameconfig.BucketLuck,
}

// IsBoostable reports whether a bucket may be driven by a server event.
func IsBoostable(bucket string) bool {
	for _, b := range BoostableBuckets {
		if b == bucket {
			return true
		}
	}
	return false
}
