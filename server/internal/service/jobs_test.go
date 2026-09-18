package service

import (
	"strings"
	"testing"
	"time"
)

// A fixed period turns over exactly on its boundary and nowhere else.
func TestEveryTurnsOverOnTheBoundary(t *testing.T) {
	p := Every(5 * time.Minute)
	base := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	if p(base) != p(base.Add(4*time.Minute+59*time.Second)) {
		t.Fatal("two moments inside one five-minute window got different periods")
	}
	if p(base) == p(base.Add(5*time.Minute)) {
		t.Fatal("the next window got the same period")
	}
}

// A daily period turns over at its hour, in UTC, wherever the server lives.
func TestDailyUTCTurnsOverAtItsHour(t *testing.T) {
	p := DailyUTC(3)
	before := time.Date(2026, 9, 14, 2, 59, 0, 0, time.UTC)
	after := time.Date(2026, 9, 14, 3, 0, 0, 0, time.UTC)
	if p(before) != "2026-09-13" || p(after) != "2026-09-14" {
		t.Fatalf("DailyUTC(3): %s at 02:59, %s at 03:00", p(before), p(after))
	}
	istanbul := time.FixedZone("TRT", 3*3600)
	if p(after.In(istanbul)) != "2026-09-14" {
		t.Fatalf("the same instant in another zone got %s", p(after.In(istanbul)))
	}
}

// Every scheduled job is named once, has a period and a body.
func TestScheduledJobsAreWellFormed(t *testing.T) {
	seen := map[string]bool{}
	for _, j := range ScheduledJobs() {
		if j.Name == "" || j.Period == nil || j.Run == nil {
			t.Fatalf("job %+v is missing a name, a period or a body", j.Name)
		}
		if seen[j.Name] {
			t.Fatalf("two jobs are called %q; they would share one claim row", j.Name)
		}
		seen[j.Name] = true
	}
	for _, want := range []string{"reputation_decay", "leaderboards", "mail_purge",
		"deleted_ledger_purge", "analytics_purge", "iap_notifications", "cosmetics_lapse", "referral_rewards", "promo_failures_purge", "kpi_rollup"} {
		if !seen[want] {
			t.Fatalf("the %s job is not scheduled", want)
		}
	}
}

// Scheduled work reads the balance live, never a copy taken at boot.
func TestJobsReadTheLiveBalance(t *testing.T) {
	src := serviceSource(t, "jobs.go")
	if !strings.Contains(src, "d.Config = r.Store.Get()") {
		t.Fatal("the job runner no longer reads the live balance for each run")
	}
}
