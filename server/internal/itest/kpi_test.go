//go:build integration

package itest

import (
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// A day is rolled up from what happened on it, UTC midnight to midnight: who
// played and joined, what Production sold and Apple refunded, and how diamonds
// moved. Written again, it says the same; the panel reads it back.
func TestTheDayIsRolledUp(t *testing.T) {
	w := newWorld(t)
	// A day no other test touches, so the counts are this test's alone.
	day := time.Date(2021, 3, 14, 0, 0, 0, 0, time.UTC)
	at := func(h int) time.Time { return day.Add(time.Duration(h) * time.Hour) }

	a, b := w.player(5, 0), w.player(5, 0)
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1`, a.ID, at(9))
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1`, b.ID, day.AddDate(0, 0, -30))
	w.exec(`INSERT INTO app.player_days (player_id, day) VALUES ($1, $3), ($2, $3), ($2, $4)`,
		a.ID, b.ID, day, day.AddDate(0, 0, -1))
	// A lord who joined that day and has since left still joined that day.
	w.exec(`INSERT INTO app.deleted_accounts (player_id, joined_at, deleted_at, level, diamonds, diamond_debt)
	        VALUES ($1, $2, $3, 1, 0, 0)`, uuid.New(), at(20), at(22))

	buy := func(p uuid.UUID, id, env string, cents int64, bought time.Time, refunded *time.Time) {
		state := "granted"
		if refunded != nil {
			state = "refunded"
		}
		w.exec(`INSERT INTO app.iap_transactions (platform, transaction_id, original_transaction_id, player_id,
		          product_id, store_product_id, kind, environment, purchased_at, usd_cents, signed, state, refunded_at)
		        VALUES ('apple', $1, $1, $2, 'gems_330', 'com.emperors.game.gems.330', 'consumable', $3, $4, $5, 'x', $6, $7)`,
			id, p, env, bought, cents, state, refunded)
	}
	tag := uuid.NewString()[:8]
	buy(a.ID, "KPI-A-"+tag, "Production", 499, at(10), nil)
	buy(b.ID, "KPI-B-"+tag, "Sandbox", 499, at(11), nil) // not revenue
	refundedAt := at(15)
	buy(b.ID, "KPI-C-"+tag, "Production", 99, day.AddDate(0, 0, -5), &refundedAt) // refunded that day

	// Diamonds that day: 30 earned, 600 bought, 20 spent -- the balance moved with them.
	for _, r := range []struct {
		delta       int64
		reason, cls string
	}{{30, "levelup", "earned"}, {600, "purchase", "purchased"}, {-20, "market_reroll", "spent"}} {
		w.exec(`UPDATE app.players SET diamonds = diamonds + $2 WHERE id = $1`, a.ID, r.delta)
		w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class, created_at)
		        SELECT $1, $2, $2, diamonds, $3, $4, $5 FROM app.players WHERE id = $1`, a.ID, r.delta, r.reason, r.cls, at(12))
	}

	run := func() {
		for _, j := range service.ScheduledJobs() {
			if j.Name == "kpi_rollup" {
				if err := j.Run(w.ctx, w.d, day.AddDate(0, 0, 1).Add(time.Hour)); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	want := sqlcdb.AppDailyKpi{Dau: 2, NewLords: 2, Payers: 1, Purchases: 1, GrossCents: 499, RefundCents: 99,
		DiamondsEarned: 30, DiamondsBought: 600, DiamondsSpent: 20}
	check := func(when string) {
		var got sqlcdb.AppDailyKpi
		if err := pool.QueryRow(w.ctx, `SELECT dau, new_lords, payers, purchases, gross_cents, refund_cents,
		        diamonds_earned, diamonds_bought, diamonds_spent FROM app.daily_kpi WHERE day = $1`, day).Scan(
			&got.Dau, &got.NewLords, &got.Payers, &got.Purchases, &got.GrossCents, &got.RefundCents,
			&got.DiamondsEarned, &got.DiamondsBought, &got.DiamondsSpent); err != nil {
			t.Fatalf("%s: %v", when, err)
		}
		got.Day, got.ComputedAt = want.Day, want.ComputedAt
		if got != want {
			t.Fatalf("%s: the day rolled up as %+v; want %+v", when, got, want)
		}
	}
	run()
	check("the first run")
	run()
	check("written again")

	svc := &admin.Service{Pool: pool, Config: gameconfig.NewStore(w.d.Config, nil, nil),
		Now: func() int64 { return day.AddDate(0, 0, 2).Unix() }}
	an, err := svc.GetAnalytics(w.ctx, 7, 5)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range an.KPIs {
		if k.Day == day.Format("2006-01-02") {
			if k.NetCents != 400 || k.ARPDAUCentiCent != 400*100/2 || k.ConversionBP != 5000 {
				t.Fatalf("the panel's day: %+v", k)
			}
			return
		}
	}
	t.Fatalf("the panel does not show the rolled-up day: %+v", an.KPIs)
}
