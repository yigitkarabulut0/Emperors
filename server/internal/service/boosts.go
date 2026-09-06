package service

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
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
}

// NewBoosts starts empty, which is exactly "no event running".
func NewBoosts(pool *pgxpool.Pool, log *slog.Logger, now func() time.Time) *Boosts {
	b := &Boosts{pool: pool, log: log, now: now}
	empty := map[string]int64{}
	b.current.Store(&empty)
	return b
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
	rows, err := sqlcdb.New(b.pool).ActiveBoosts(ctx, b.now())
	if err != nil {
		return err
	}
	next := make(map[string]int64, len(rows))
	for _, r := range rows {
		next[r.Bucket] += r.AmountBp
	}
	b.current.Store(&next)
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
var BoostableBuckets = []string{
	gameconfig.BucketCollectIncome,
	gameconfig.BucketXP,
	gameconfig.BucketTaxIncome,
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
