package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Job is one piece of scheduled work: the world's clock, not a player's.
//
// Almost everything in this server settles lazily when a player asks -- energy,
// estate income, the shop. What cannot is work that belongs to the world
// rather than to anyone who will send a request: a kingdom that stopped playing
// still has to decay, a leaderboard still has to be rebuilt, a letter still has
// to expire.
type Job struct {
	Name string
	// Period names the slice of time the job runs once in, e.g. "2026-09-14"
	// for a daily job. It runs when the period it last claimed is a different
	// one. Pure: a function of the time it is given.
	Period func(now time.Time) string
	// Lease is how long a claim holds before a process that died mid-run is
	// assumed gone and the job may be claimed again. Also the run's timeout.
	Lease time.Duration
	// RetryOnFail re-runs a failed job on the next tick. Off for work that must
	// never happen twice and can be skipped once (the reputation decay).
	RetryOnFail bool
	Run         func(ctx context.Context, d Deps, now time.Time) error
}

// Every is a period of a fixed length, aligned to the Unix epoch: "5m0s:5923104".
func Every(d time.Duration) func(time.Time) string {
	secs := int64(d / time.Second)
	if secs < 1 {
		secs = 1
	}
	return func(t time.Time) string { return fmt.Sprintf("%s:%d", d, t.Unix()/secs) }
}

// DailyUTC is one period per UTC day, turning over at the given hour: a job
// on DailyUTC(3) runs once between 03:00 one day and 03:00 the next.
func DailyUTC(hour int) func(time.Time) string {
	return func(t time.Time) string {
		return t.UTC().Add(-time.Duration(hour) * time.Hour).Format("2006-01-02")
	}
}

// Runner runs the jobs on a tick.
//
// It reads the live balance on every run. The loops it replaces were handed the
// bundle loaded at boot, so a published balance never reached them: a changed
// decay rate did nothing until the next deploy.
type Runner struct {
	Store *gameconfig.Store
	Base  Deps
	Log   *slog.Logger
	Now   func() time.Time
	// Instance names this process in the claim rows, for whoever reads them.
	Instance string
	Jobs     []Job
}

// Run ticks until the context ends, catching up at once rather than waiting
// out the first tick.
func (r *Runner) Run(ctx context.Context, tick time.Duration) {
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		r.Tick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Tick runs every job that is due. Exposed so tests and the dev tools can drive
// the clock themselves.
func (r *Runner) Tick(ctx context.Context) {
	for _, j := range r.Jobs {
		if ctx.Err() != nil {
			return
		}
		r.runOne(ctx, j)
	}
}

func (r *Runner) deps() Deps {
	d := r.Base
	if r.Store != nil {
		d.Config = r.Store.Get()
	}
	if r.Now != nil {
		d.Now = r.Now
	}
	return d
}

func (r *Runner) runOne(ctx context.Context, j Job) {
	now := r.Now()
	lease := j.Lease
	if lease <= 0 {
		lease = 10 * time.Minute
	}
	q := sqlcdb.New(r.Base.Pool)
	if _, err := q.ClaimJob(ctx, sqlcdb.ClaimJobParams{
		JobName: j.Name, PeriodKey: j.Period(now), ClaimedBy: r.Instance,
		LeaseSeconds: int32(lease / time.Second),
	}); err != nil {
		if !errors.Is(err, pgx.ErrNoRows) && r.Log != nil {
			r.Log.Warn("job claim failed", "job", j.Name, "err", err)
		}
		return // not due, or another process holds it
	}

	runCtx, cancel := context.WithTimeout(ctx, lease)
	err := j.Run(runCtx, r.deps(), now)
	cancel()

	// Recorded on a context of its own: a run that timed out must still say so.
	fctx, fcancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer fcancel()
	if err != nil {
		if r.Log != nil {
			r.Log.Error("job failed", "job", j.Name, "err", err, "retry", j.RetryOnFail)
		}
		msg := err.Error()
		if ferr := q.FinishJobFailed(fctx, sqlcdb.FinishJobFailedParams{
			JobName: j.Name, LastError: &msg, Retry: j.RetryOnFail,
		}); ferr != nil && r.Log != nil {
			r.Log.Warn("job failure not recorded", "job", j.Name, "err", ferr)
		}
		return
	}
	if ferr := q.FinishJobOK(fctx, j.Name); ferr != nil && r.Log != nil {
		r.Log.Warn("job success not recorded", "job", j.Name, "err", ferr)
	}
}
