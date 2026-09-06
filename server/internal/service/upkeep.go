package service

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Upkeep is the game's only scheduled work.
//
// Everything else in this server is request-driven and lazily settled — energy,
// estate income and the shop are all computed on read, which is why there is no
// cron anywhere. Reputation decay cannot be: it is a property of the WORLD, not
// of a player, and a kingdom that stopped playing is exactly the one that never
// sends a request to settle it on.
//
// Without this the ladder is frozen. A kingdom that quit in month one keeps its
// rank forever, and the leaderboard stops meaning "who is fighting now".
type Upkeep struct {
	Deps Deps
	Log  *slog.Logger
	Now  func() time.Time
}

// Run decays kingdom reputation once per UTC day until the context ends.
//
// Polled rather than scheduled for midnight: a ticker that only fires at 00:00
// misses the day entirely if the process is down at that moment, and this is
// work that must not be skipped. Checking hourly and claiming the day in the
// database makes the loop idempotent — a restart, a second replica or a deploy
// mid-tick all converge on exactly one decay per day.
func (u Upkeep) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()

	u.once(ctx) // catch up immediately rather than waiting out the first tick
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			u.once(ctx)
		}
	}
}

// RunLeaderboards rebuilds the ranked snapshots on a shorter cycle.
//
// Separate from the daily upkeep because it is a different kind of work: the
// decay must happen exactly once a day, and this should happen often enough
// that a rank feels live. Both are cheap; neither is worth a scheduler.
func (u Upkeep) RunLeaderboards(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()

	for {
		if err := u.Deps.RefreshLeaderboards(ctx); err != nil && u.Log != nil {
			u.Log.Warn("leaderboard refresh failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (u Upkeep) once(ctx context.Context) {
	bp := u.Deps.Config.Kingdoms.Reputation.DecayBPPerDay
	if bp <= 0 {
		return
	}
	day := u.Now().UTC().Format("2006-01-02")

	q := sqlcdb.New(u.Deps.Pool)
	if _, err := q.ClaimDecayDay(ctx, day); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return // already done today, by this process or another
		}
		u.Log.Warn("could not claim the reputation decay day", "err", err, "day", day)
		return
	}

	if err := q.DecayReputation(ctx, bp); err != nil {
		// The day is already claimed, so this decay is lost rather than retried.
		// That is the right trade: a missed day is a rounding error against a 2%
		// rate, and retrying risks applying it twice.
		u.Log.Error("reputation decay failed", "err", err, "day", day)
		return
	}
	u.Log.Info("reputation decayed", "day", day, "bp", bp)
}
