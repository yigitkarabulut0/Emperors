//go:build integration

package itest

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/presence"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

const itestPassword = "itest-password-1"

// withPassword gives a lord a password to confirm a deletion with.
func (w *world) withPassword(p sqlcdb.AppPlayer) {
	w.t.Helper()
	hash, err := auth.HashPassword(itestPassword)
	if err != nil {
		w.t.Fatal(err)
	}
	if _, err := w.q.CreateIdentity(w.ctx, sqlcdb.CreateIdentityParams{
		PlayerID: p.ID, Kind: "password", Subject: p.Username, SecretHash: &hash,
	}); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) count(sql string, args ...any) int {
	w.t.Helper()
	var n int
	if err := pool.QueryRow(w.ctx, sql, args...).Scan(&n); err != nil {
		w.t.Fatal(err)
	}
	return n
}

func (w *world) runJob(name string) {
	w.t.Helper()
	for _, j := range service.ScheduledJobs() {
		if j.Name == name {
			if err := j.Run(w.ctx, w.d, w.now); err != nil {
				w.t.Fatalf("%s: %v", name, err)
			}
			return
		}
	}
	w.t.Fatalf("no job called %s", name)
}

// A deleted account leaves what a later refund needs, and nothing personal.
func TestADeletionLeavesWhatARefundNeeds(t *testing.T) {
	w := newWorld(t)
	p := w.player(3, 0)
	w.withPassword(p)
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); err != nil {
		t.Fatal(err)
	}
	if err := presence.NewStore(pool).TouchSeen(w.ctx, []uuid.UUID{p.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.RecordEvents(w.ctx, p.ID, []service.ClientEvent{{Name: "app_open"}}); err != nil {
		t.Fatal(err)
	}
	held := w.reload(p.ID).Diamonds

	if err := w.d.DeleteAccount(w.ctx, p.ID, itestPassword); err != nil {
		t.Fatal(err)
	}
	gone, err := w.q.GetDeletedAccount(w.ctx, p.ID)
	if err != nil {
		t.Fatalf("the deletion left no record: %v", err)
	}
	if gone.Diamonds != held || gone.Level != 3 || !gone.JoinedAt.Equal(p.CreatedAt) || !gone.DeletedAt.Equal(w.now.Truncate(time.Microsecond)) {
		t.Fatalf("recorded %+v; want %d diamonds, level 3, joined %v, left %v", gone, held, p.CreatedAt, w.now)
	}
	if n := w.count(`SELECT count(*) FROM app.analytics_events WHERE player_id = $1`, p.ID); n != 0 {
		t.Fatalf("%d of the deleted account's events are still kept", n)
	}
	if n := w.count(`SELECT count(*) FROM app.player_days WHERE player_id = $1`, p.ID); n == 0 {
		t.Fatal("the days the deleted account played were forgotten")
	}
	if n := w.count(`SELECT count(*) FROM app.diamond_ledger WHERE player_id = $1`, p.ID); n != 1 {
		t.Fatalf("the deleted account's diamond history holds %d rows, want 1", n)
	}

	// Ninety days on the ledger goes; the record of the deletion stays.
	w.now = w.now.Add(89 * 24 * time.Hour)
	w.runJob("deleted_ledger_purge")
	if n := w.count(`SELECT count(*) FROM app.diamond_ledger WHERE player_id = $1`, p.ID); n != 1 {
		t.Fatal("the ledger was purged before ninety days")
	}
	w.now = w.now.Add(2 * 24 * time.Hour)
	w.runJob("deleted_ledger_purge")
	if n := w.count(`SELECT count(*) FROM app.diamond_ledger WHERE player_id = $1`, p.ID); n != 0 {
		t.Fatalf("%d ledger rows outlived the ninety days", n)
	}
	if _, err := w.q.GetDeletedAccount(w.ctx, p.ID); err != nil {
		t.Fatal("the purge took the record of the deletion with it")
	}
}

// Seeing a player records the day, and seeing them twice records it once.
func TestSeeingAPlayerRecordsTheDay(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	store := presence.NewStore(pool)
	for i := 0; i < 2; i++ {
		if err := store.TouchSeen(w.ctx, []uuid.UUID{p.ID}); err != nil {
			t.Fatal(err)
		}
	}
	if n := w.count(`SELECT count(*) FROM app.player_days WHERE player_id = $1
		AND day = (now() AT TIME ZONE 'UTC')::date`, p.ID); n != 1 {
		t.Fatalf("two flushes on one day wrote %d rows, want 1", n)
	}
}

// A player who comes every day is active on every day, not only the last.
func TestTheActiveSeriesCountsEveryDay(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	// A day long past, so nothing another test wrote shares it.
	first := time.Date(2020, 3, 2, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		w.exec(`INSERT INTO app.player_days (player_id, day) VALUES ($1, $2)`, p.ID,
			pgtype.Date{Time: first.AddDate(0, 0, i), Valid: true})
	}
	svc := &admin.Service{Pool: pool, Now: func() int64 { return first.AddDate(0, 0, 3).Unix() }}
	a, err := svc.GetAnalytics(w.ctx, 5, 15)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	for _, pt := range a.Active {
		got[pt.Day] = pt.Count
	}
	for i := 0; i < 3; i++ {
		day := first.AddDate(0, 0, i).Format("2006-01-02")
		if got[day] != 1 {
			t.Errorf("active on %s: %d, want 1 (the series: %v)", day, got[day], got)
		}
	}
}

// Retention reads the cohort a player joined, and says nothing of a day that
// has not come yet.
func TestRetentionByCohort(t *testing.T) {
	w := newWorld(t)
	joined := time.Date(2020, 6, 1, 9, 0, 0, 0, time.UTC)
	day := func(n int) pgtype.Date { return pgtype.Date{Time: joined.AddDate(0, 0, n), Valid: true} }
	stay, leave, gone := w.player(1, 0), w.player(1, 0), uuid.New()
	for _, id := range []uuid.UUID{stay.ID, leave.ID} {
		w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1`, id, joined)
	}
	w.exec(`INSERT INTO app.player_days (player_id, day) VALUES ($1, $2), ($1, $3), ($4, $2)`,
		stay.ID, day(1), day(7), gone)
	// A player who joined the same day, came back the next, then deleted their
	// account: still one of the cohort, still counted as having come back.
	w.exec(`INSERT INTO app.deleted_accounts (player_id, joined_at, deleted_at, level, diamonds, diamond_debt)
	        VALUES ($1, $2, $3, 2, 0, 0)`, gone, joined, joined.AddDate(0, 0, 2))

	svc := &admin.Service{Pool: pool, Now: func() int64 { return joined.AddDate(0, 0, 10).Unix() }}
	a, err := svc.GetAnalytics(w.ctx, 30, 15)
	if err != nil {
		t.Fatal(err)
	}
	var c *admin.Cohort
	for i := range a.Retention {
		if a.Retention[i].Day == "2020-06-01" {
			c = &a.Retention[i]
		}
	}
	if c == nil {
		t.Fatalf("no cohort for the day they joined: %+v", a.Retention)
	}
	if c.Size != 3 || c.D1 == nil || *c.D1 != 2 || c.D7 == nil || *c.D7 != 1 {
		t.Fatalf("cohort %+v; want 3 joined, 2 back on day 1, 1 on day 7", *c)
	}
	if c.D30 != nil {
		t.Fatalf("day 30 answered %d ten days in", *c.D30)
	}
}

// The listed events are kept, the rest dropped, and a player past the hour's
// allowance is kept no more.
func TestEventsKeepToTheListAndTheAllowance(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	res, err := w.d.RecordEvents(w.ctx, p.ID, []service.ClientEvent{
		{Name: "screen", Props: map[string]any{"name": "collect"}, At: w.now.Unix()},
		{Name: "screen", Props: map[string]any{"name": "Not an id"}},
		{Name: "no_such_event"},
		{Name: "app_close", Props: map[string]any{"seconds": float64(90)}, At: w.now.Add(-30 * 24 * time.Hour).Unix()},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Recorded != 2 || res.Dropped != 2 {
		t.Fatalf("recorded %d, dropped %d; want 2 and 2", res.Recorded, res.Dropped)
	}
	var withClock, withoutClock int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FILTER (WHERE client_at IS NOT NULL),
		count(*) FILTER (WHERE client_at IS NULL) FROM app.analytics_events WHERE player_id = $1`,
		p.ID).Scan(&withClock, &withoutClock); err != nil {
		t.Fatal(err)
	}
	if withClock != 1 || withoutClock != 1 {
		t.Fatalf("%d events kept the phone's clock and %d did not; want 1 and 1", withClock, withoutClock)
	}

	w.exec(`INSERT INTO app.analytics_events (player_id, name, created_at)
	        SELECT $1, 'screen', $2 FROM generate_series(1, 600)`, p.ID, w.now.Add(-time.Minute))
	res, err = w.d.RecordEvents(w.ctx, p.ID, []service.ClientEvent{{Name: "app_open"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Recorded != 0 || res.Dropped != 1 {
		t.Fatalf("past the allowance: recorded %d, dropped %d", res.Recorded, res.Dropped)
	}
	w.now = w.now.Add(2 * time.Hour)
	if res, _ = w.d.RecordEvents(w.ctx, p.ID, []service.ClientEvent{{Name: "app_open"}}); res.Recorded != 1 {
		t.Fatal("the allowance did not come back the next hour")
	}

	// And after 180 days they are purged.
	w.now = w.now.Add(181 * 24 * time.Hour)
	w.runJob("analytics_purge")
	if n := w.count(`SELECT count(*) FROM app.analytics_events WHERE player_id = $1 AND created_at < $2`,
		p.ID, w.now.Add(-180*24*time.Hour)); n != 0 {
		t.Fatalf("%d events outlived 180 days", n)
	}
}
