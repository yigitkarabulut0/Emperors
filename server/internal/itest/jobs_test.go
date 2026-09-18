//go:build integration

package itest

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// A job runs once per period, however many ticks and processes see it.
func TestAJobRunsOncePerPeriod(t *testing.T) {
	w := newWorld(t)
	runs := 0
	name := "itest_once_" + uuid.NewString()[:8]
	job := service.Job{
		Name: name, Period: service.Every(time.Hour), Lease: time.Minute,
		Run: func(context.Context, service.Deps, time.Time) error { runs++; return nil },
	}
	a := &service.Runner{Base: w.d, Now: func() time.Time { return w.now }, Instance: "a", Jobs: []service.Job{job}}
	b := &service.Runner{Base: w.d, Now: func() time.Time { return w.now }, Instance: "b", Jobs: []service.Job{job}}

	a.Tick(w.ctx)
	b.Tick(w.ctx)
	a.Tick(w.ctx)
	if runs != 1 {
		t.Fatalf("three ticks by two processes in one period ran the job %d times", runs)
	}
	w.now = w.now.Add(time.Hour)
	b.Tick(w.ctx)
	if runs != 2 {
		t.Fatalf("the next period ran the job %d times in total, want 2", runs)
	}
}

// A job that may retry runs again on the next tick after failing; one that may
// not waits for the next period.
func TestAFailedJobRetriesOnlyWhenAllowed(t *testing.T) {
	w := newWorld(t)
	for _, retry := range []bool{true, false} {
		runs := 0
		job := service.Job{
			Name: "itest_fail_" + uuid.NewString()[:8], Period: service.Every(time.Hour),
			Lease: time.Minute, RetryOnFail: retry,
			Run: func(context.Context, service.Deps, time.Time) error {
				runs++
				return errors.New("itest: this job fails")
			},
		}
		r := &service.Runner{Base: w.d, Now: func() time.Time { return w.now }, Instance: "a", Jobs: []service.Job{job}}
		r.Tick(w.ctx)
		r.Tick(w.ctx)
		want := 1
		if retry {
			want = 2
		}
		if runs != want {
			t.Fatalf("retry=%v: two ticks ran a failing job %d times, want %d", retry, runs, want)
		}
		var errText *string
		if err := pool.QueryRow(w.ctx, `SELECT last_error FROM app.job_runs WHERE job_name = $1`,
			job.Name).Scan(&errText); err != nil || errText == nil {
			t.Fatalf("retry=%v: the failure was not recorded (%v)", retry, err)
		}
	}
}

// A claim whose process died mid-run is taken over once its lease runs out.
func TestAnAbandonedClaimIsTakenOver(t *testing.T) {
	w := newWorld(t)
	name := "itest_lease_" + uuid.NewString()[:8]
	period := service.Every(time.Hour)(w.now)
	w.exec(`INSERT INTO app.job_runs (job_name, period_key, claimed_at, claimed_by)
	        VALUES ($1, $2, now() - interval '5 seconds', 'a process that died')`, name, period)

	runs := 0
	job := service.Job{
		Name: name, Period: service.Every(time.Hour), Lease: 2 * time.Second,
		Run: func(context.Context, service.Deps, time.Time) error { runs++; return nil },
	}
	r := &service.Runner{Base: w.d, Now: func() time.Time { return w.now }, Instance: "b", Jobs: []service.Job{job}}
	r.Tick(w.ctx)
	if runs != 1 {
		t.Fatalf("a claim five seconds past a two-second lease was not taken over (ran %d)", runs)
	}
}
