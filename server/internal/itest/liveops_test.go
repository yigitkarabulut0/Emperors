//go:build integration

package itest

import (
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// live gives a world the boost poll, at the top of its hour, and a way to set
// the hour's event as the panel's table would hold it.
type live struct {
	*world
	boosts *service.Boosts
	hour   int64
}

func newLive(t *testing.T) *live {
	t.Helper()
	w := newWorld(t)
	l := &live{world: w, boosts: service.NewBoosts(pool, slog.Default(), func() time.Time { return w.now })}
	w.d.Boosts = l.boosts
	l.hour = liveops.Hour(w.now)
	w.now = liveops.HourStart(l.hour).Add(time.Minute)
	t.Cleanup(func() {
		_, _ = pool.Exec(w.ctx, `DELETE FROM admin.hourly_events WHERE hour BETWEEN $1 AND $2`, l.hour-2, l.hour+30)
	})
	l.refresh()
	return l
}

// force writes the hour's event and reloads the poll. A real hour has one
// event, so the uses of the one before (kept per hour) are cleared with it.
func (l *live) force(id string) {
	l.t.Helper()
	l.exec(`INSERT INTO admin.hourly_events (hour, event_id, source) VALUES ($1, $2, 'forced')
	        ON CONFLICT (hour) DO UPDATE SET event_id = EXCLUDED.event_id, source = 'forced'`, l.hour, id)
	l.exec(`DELETE FROM app.player_hourly WHERE hour = $1`, l.hour)
	l.refresh()
}

func (l *live) refresh() {
	l.t.Helper()
	if err := l.boosts.Refresh(l.ctx); err != nil {
		l.t.Fatal(err)
	}
}

// give credits diamonds as the panel would, ledgered.
func (w *world) give(p sqlcdb.AppPlayer, n int64) {
	w.t.Helper()
	before := w.reload(p.ID)
	after, err := w.q.CreditDiamonds(w.ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: n})
	if err != nil {
		w.t.Fatal(err)
	}
	if err := ledger.Diamonds(w.ctx, w.q, before, after, n, ledger.AdminGrant, "itest"); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) collect(p sqlcdb.AppPlayer) *service.CollectResult {
	w.t.Helper()
	p = w.reload(p.ID)
	res, err := w.d.Collect(w.ctx, p.ID, w.d.Config.Jobs.Jobs[0].ID, p.ActionSeq+1)
	if err != nil {
		w.t.Fatal(err)
	}
	return res
}

func (w *world) deeds(p sqlcdb.AppPlayer, kind string, n int64) {
	w.t.Helper()
	if err := w.d.DevAddDeeds(w.ctx, p.ID, kind, n); err != nil {
		w.t.Fatal(err)
	}
}

// letter is one letter, its attachments read.
type letter struct {
	Title, Body string
	Grant       gameconfig.RewardBundle
}

// letters is a lord's letters whose idempotency key begins with prefix.
func (w *world) letters(p sqlcdb.AppPlayer, prefix string) []letter {
	w.t.Helper()
	rows, err := pool.Query(w.ctx, `SELECT id, title, body, attachments FROM app.mail WHERE player_id = $1 AND idem_key LIKE $2 || '%' ORDER BY id`, p.ID, prefix)
	if err != nil {
		w.t.Fatal(err)
	}
	defer rows.Close()
	var out []letter
	for rows.Next() {
		var id int64
		var raw []byte
		var m letter
		if err := rows.Scan(&id, &m.Title, &m.Body, &raw); err != nil {
			w.t.Fatal(err)
		}
		if err := json.Unmarshal(raw, &m.Grant); err != nil {
			w.t.Fatal(err)
		}
		out = append(out, m)
	}
	return out
}

// The hour's event runs its minutes from the top of the hour: Gold Rush pays a
// collect double, the snapshot says so and for how long, and after its
// quarter-hour a collect pays as before.
func TestAnHourlyEventRunsItsMinutes(t *testing.T) {
	l := newLive(t)
	p := l.player(10, 0)

	l.force("none")
	quiet := l.collect(p).GoldGained
	snap, _ := l.d.GetState(l.ctx, p.ID)
	if snap.Live.Hourly.ID != "" || snap.Live.Hourly.NextIn < 58*60 {
		t.Fatalf("a quiet hour: %+v", snap.Live.Hourly)
	}

	l.force("gold_rush")
	snap, _ = l.d.GetState(l.ctx, p.ID)
	h := snap.Live.Hourly
	if h.ID != "gold_rush" || !h.Active || h.Kind != "boost" || h.BP != 10000 || h.EffectiveBP != 10000 ||
		h.EndsIn < 13*60 || h.EndsIn > 14*60 {
		t.Fatalf("Gold Rush on the snapshot: %+v", h)
	}
	if rush := l.collect(p).GoldGained; rush != 2*quiet {
		t.Fatalf("a collect in Gold Rush paid %d; a quiet one %d", rush, quiet)
	}

	l.now = liveops.HourStart(l.hour).Add(16 * time.Minute)
	snap, _ = l.d.GetState(l.ctx, p.ID)
	if snap.Live.Hourly.Active || snap.Live.Hourly.EndsIn != 0 || snap.Live.Hourly.ID != "gold_rush" {
		t.Fatalf("a quarter-hour on: %+v", snap.Live.Hourly)
	}
	if after := l.collect(p).GoldGained; after != quiet {
		t.Fatalf("a collect after Gold Rush paid %d, want %d", after, quiet)
	}
}

// Quartermaster's Sale halves the refill, Fresh Wares rerolls the market for
// nothing once, the courier's gift is taken once, and Busy Hands counts the
// day's quests twice.
func TestTheHourlyEventsDoWhatTheySay(t *testing.T) {
	l := newLive(t)
	p := l.player(10, 0)
	l.give(p, 200)
	l.exec(`UPDATE app.players SET energy_milli = 0 WHERE id = $1`, p.ID)

	l.force("quartermasters_sale")
	st, err := l.d.GetStore(l.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	refill := st.Goods[0]
	if refill.ID != "energy_refill" || refill.Diamonds != 10 || refill.RegularDiamonds != 20 || refill.SaleEndsIn <= 0 {
		t.Fatalf("the refill on sale: %+v", refill)
	}
	p = l.reload(p.ID)
	if _, err := l.d.BuyStoreGood(l.ctx, p.ID, "energy_refill", service.PayDiamonds, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	if got := l.reload(p.ID).Diamonds; got != 190 {
		t.Fatalf("the refill on sale cost %d", 200-got)
	}

	l.force("fresh_wares")
	shop, err := l.d.GetShop(l.ctx, p.ID)
	if err != nil || shop.FreeRerolls != 1 || !shop.CanAffordRoll {
		t.Fatalf("Fresh Wares on the market: %+v %v", shop, err)
	}
	before := shop.Offers[0].Item
	p = l.reload(p.ID)
	after, err := l.d.RerollShop(l.ctx, p.ID, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if p2 := l.reload(p.ID); p2.Diamonds != 190 || p2.ShopRerollsUsed != p.ShopRerollsUsed || p2.ActionSeq != p.ActionSeq+1 {
		t.Fatalf("the free reroll: %d diamonds, %d rerolls used (was %d), seq %d", p2.Diamonds, p2.ShopRerollsUsed, p.ShopRerollsUsed, p2.ActionSeq)
	}
	if after.FreeRerolls != 0 || after.Offers[0].Item == before {
		t.Fatalf("after the free reroll: %d free, shelf unchanged %v", after.FreeRerolls, after.Offers[0].Item == before)
	}
	p = l.reload(p.ID)
	if _, err := l.d.RerollShop(l.ctx, p.ID, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	if got := l.reload(p.ID).Diamonds; got >= 190 {
		t.Fatalf("the second reroll was free too (%d diamonds)", got)
	}

	l.force("royal_courier")
	if b, err := l.d.GetBadges(l.ctx, p.ID); err != nil || !b.Hourly {
		snap, _ := l.d.GetState(l.ctx, p.ID)
		t.Fatalf("the courier's gift is not flagged (%v): %+v", err, snap.Live.Hourly)
	}
	claim, err := l.d.ClaimHourly(l.ctx, p.ID)
	if err != nil || claim.Granted.Tokens["cart"] != 1 {
		t.Fatalf("the courier's gift: %+v %v", claim, err)
	}
	if _, err := l.d.ClaimHourly(l.ctx, p.ID); !errors.Is(err, service.ErrHourlyClaimed) {
		t.Fatalf("a second gift: %v", err)
	}
	if b, _ := l.d.GetBadges(l.ctx, p.ID); b.Hourly {
		t.Fatal("a taken gift is still flagged")
	}
	l.force("none")
	if _, err := l.d.ClaimHourly(l.ctx, p.ID); !errors.Is(err, service.ErrHourlyNone) {
		t.Fatalf("a gift in a quiet hour: %v", err)
	}

	progress := func() int64 {
		qv, err := l.d.GetQuests(l.ctx, p.ID)
		if err != nil {
			t.Fatal(err)
		}
		var n int64
		for _, q := range qv.Quests {
			n += q.Progress
		}
		return n
	}
	// The day's three are DRAWN from the pool (a hash of the lord and the day),
	// and the pool has grown with every wave -- so a board with nothing on it a
	// collect moves is an ordinary draw, and this test used to fail on one. The
	// board is frozen once it exists, so it is read once to create it and then
	// pinned to three the collect does move: what is under test here is Busy
	// Hands doubling a counter, not which counters were drawn.
	if _, err := l.d.GetQuests(l.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	l.exec(`UPDATE app.player_quests SET quest_ids = ARRAY['collect_20','collect_60','energy_150']
	        WHERE player_id = $1`, p.ID)

	start := progress()
	l.collect(p)
	plain := progress() - start
	l.force("busy_hands")
	mid := progress()
	l.collect(p)
	if busy := progress() - mid; plain == 0 || busy != 2*plain {
		t.Fatalf("a collect moved the quests %d; in Busy Hands %d", plain, busy)
	}
}

// The job writes the hour and the next down as the roll has them; the panel
// may set only hours to come, a day ahead at most.
func TestHoursAreWrittenDownAndSetAhead(t *testing.T) {
	l := newLive(t)
	l.exec(`DELETE FROM admin.hourly_events WHERE hour BETWEEN $1 AND $2`, l.hour-30, l.hour+30)
	l.runJob("hourly_events")
	var got []sqlcdb.AdminHourlyEvent
	rows, _ := l.q.ListHourlyEvents(l.ctx, sqlcdb.ListHourlyEventsParams{FromHour: l.hour, ToHour: l.hour + 1})
	got = append(got, rows...)
	if len(got) != 2 || got[0].Source != "roll" {
		t.Fatalf("written down: %+v", got)
	}
	if want := liveops.HourlyAt(l.d.ShopSecret, l.d.Config.LiveOps.Hourly, nil, l.hour); got[0].EventID != want {
		t.Fatalf("the hour was written as %s; the roll says %s", got[0].EventID, want)
	}

	if err := l.d.SetHourlySlot(l.ctx, l.hour, "gold_rush", "itest", ""); !errors.Is(err, service.ErrHourStarted) {
		t.Fatalf("setting the running hour: %v", err)
	}
	if err := l.d.SetHourlySlot(l.ctx, l.hour+25, "gold_rush", "itest", ""); !errors.Is(err, service.ErrHourTooFar) {
		t.Fatalf("setting a day and more ahead: %v", err)
	}
	if err := l.d.SetHourlySlot(l.ctx, l.hour+2, "dragon_hour", "itest", ""); !errors.Is(err, service.ErrNoSuchHourly) {
		t.Fatalf("an event the table has not got: %v", err)
	}
	slot := func() service.HourSlot {
		sched, err := l.d.HourlySchedule(l.ctx)
		if err != nil {
			t.Fatal(err)
		}
		for _, s := range sched {
			if s.Hour == l.hour+2 {
				return s
			}
		}
		t.Fatal("the schedule has not got the hour")
		return service.HourSlot{}
	}
	if err := l.d.SetHourlySlot(l.ctx, l.hour+2, "gold_rush", "itest", "launch"); err != nil {
		t.Fatal(err)
	}
	if s := slot(); s.EventID != "gold_rush" || s.Source != "forced" || s.SetBy != "itest" || !s.Settable {
		t.Fatalf("a forced hour: %+v", s)
	}
	if err := l.d.SetHourlySlot(l.ctx, l.hour+2, "none", "itest", ""); err != nil {
		t.Fatal(err)
	}
	if s := slot(); s.EventID != "none" || s.Source != "skipped" {
		t.Fatalf("a skipped hour: %+v", s)
	}
	if err := l.d.SetHourlySlot(l.ctx, l.hour+2, "", "itest", ""); err != nil {
		t.Fatal(err)
	}
	if s := slot(); s.Source != "predicted" {
		t.Fatalf("an hour given back to the roll: %+v", s)
	}
}

// A festival: its bonus on for everyone, points under the day's cap, tasks
// and milestones claimed once, and its close paying places and leftovers by
// letter, once.
func TestAFestivalFromScheduleToClose(t *testing.T) {
	l := newLive(t)
	l.force("none")
	start := l.now.Add(-time.Minute)
	row, err := l.d.ScheduleFestival(l.ctx, "harvest_festival", start, "itest", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(l.ctx, `UPDATE admin.live_events SET revoked_at = now() WHERE id = $1 AND settled_at IS NULL`, row.ID)
	})
	if _, err := l.d.ScheduleFestival(l.ctx, "blood_moon", start.Add(24*time.Hour), "itest", ""); !errors.Is(err, service.ErrFestivalClash) {
		t.Fatalf("a festival over another: %v", err)
	}
	l.refresh()

	p, rival, late := l.player(10, 0), l.player(10, 0), l.player(10, 0)
	for i := 0; i < 3; i++ {
		l.collect(p)
	}
	ev, err := l.d.GetEvents(l.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	f := ev.Current
	if f == nil || f.ID != row.ID || !f.Running || f.Points != 3 || f.Tasks[0].Progress != 3 || f.Day != 1 ||
		f.EffectiveBP != 2500 || f.DayCap != 600 || len(f.Tasks) != 5 || len(f.Milestones) != 4 {
		t.Fatalf("the running festival: %+v", f)
	}
	// Nine since Wave 5: Honour Hour joined, its share taken from "none".
	if len(ev.HourlyTable) != 9 {
		t.Fatalf("the hourly table: %d rows", len(ev.HourlyTable))
	}

	l.deeds(p, "collects", 1000)
	f = mustEvents(t, l, p).Current
	if f.Points != 600 || f.DayPoints != 600 || !f.Tasks[0].Done || f.Claimable != 2 || f.Place != 1 {
		t.Fatalf("a day's cap: %+v", f)
	}
	one := 0
	if _, err := l.d.ClaimFestival(l.ctx, p.ID, service.FestivalTask, &one); err != nil {
		t.Fatal(err)
	}
	if _, err := l.d.ClaimFestival(l.ctx, p.ID, service.FestivalTask, &one); !errors.Is(err, service.ErrAlreadyClaimed) {
		t.Fatalf("a task claimed twice: %v", err)
	}

	l.now = l.now.Add(24 * time.Hour)
	l.deeds(p, "collects", 500)
	if f = mustEvents(t, l, p).Current; f.Points != 1100 || f.Day != 2 {
		t.Fatalf("the second day: %+v", f)
	}
	res, err := l.d.ClaimFestival(l.ctx, p.ID, "", nil)
	if err != nil || len(res.Lines) == 0 {
		t.Fatalf("claim all: %+v %v", res, err)
	}
	if _, err := l.d.ClaimFestival(l.ctx, p.ID, "", nil); !errors.Is(err, service.ErrFestivalEmpty) {
		t.Fatalf("claim all with nothing left: %v", err)
	}
	l.deeds(rival, "collects", 350)
	l.deeds(late, "collects", 20)

	// Closed.
	l.now = row.EndsAt.Add(time.Minute)
	l.refresh()
	l.runJob("festivals_close")
	l.runJob("festivals_close")
	if m := l.letters(p, "festival:"); len(m) != 1 || !strings.Contains(m[0].Title, "1st place") ||
		m[0].Grant.Diamonds != 100 || len(m[0].Grant.Cosmetics) != 1 || m[0].Grant.Cosmetics[0] != "title_bountiful" {
		t.Fatalf("first place's letters: %+v", m)
	}
	m := l.letters(rival, "festival:")
	if len(m) != 2 || !strings.Contains(m[0].Title+m[1].Title, "2nd place") || !strings.Contains(m[0].Title+m[1].Title, "still owed") {
		t.Fatalf("second place's letters (place, and the milestone left): %+v", m)
	}
	if m := l.letters(late, "festival:"); len(m) != 1 || !strings.Contains(m[0].Title, "3rd place") {
		t.Fatalf("third place's letter: %+v", m)
	}
	if ev, _ := l.q.GetLiveEvent(l.ctx, row.ID); ev.SettledAt == nil {
		t.Fatal("the festival is not marked closed")
	}
}

func mustEvents(t *testing.T, l *live, p sqlcdb.AppPlayer) *service.EventsView {
	t.Helper()
	ev, err := l.d.GetEvents(l.ctx, p.ID)
	if err != nil || ev.Current == nil {
		t.Fatalf("events: %+v %v", ev, err)
	}
	return ev
}

// The Charter: points from what a lord does under the day's cap, the free lane
// claimed tier by tier, the royal lane opened with diamonds once.
func TestTheCharterFillsAndPays(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); err != nil {
		t.Fatal(err)
	}
	s, err := w.d.GetSeason(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if s.Points != 60 || s.Tier != 0 || s.DayPoints != 60 || s.Tiers != 50 || len(s.Charter) != 50 ||
		s.FreeDiamonds != 170 || s.RoyalDiamonds != 625 || s.Unlock.Diamonds != 900 || s.Unlock.Product != "season_pass" {
		t.Fatalf("a day's reward on the Charter: %+v", s)
	}
	w.deeds(p, "raid_wins", 100)
	if s, _ = w.d.GetSeason(w.ctx, p.ID); s.Points != 800 || s.Tier != 6 || s.Claimable != 6 {
		t.Fatalf("the day's cap: %d points, tier %d, %d to claim", s.Points, s.Tier, s.Claimable)
	}
	seven := 7
	if _, err := w.d.ClaimCharter(w.ctx, p.ID, &seven, service.LaneRoyal); !errors.Is(err, service.ErrCharterLocked) {
		t.Fatalf("a royal tier with the lane shut: %v", err)
	}
	if _, err := w.d.ClaimCharter(w.ctx, p.ID, &seven, service.LaneFree); !errors.Is(err, service.ErrCharterEmpty) {
		t.Fatalf("a tier not reached: %v", err)
	}
	res, err := w.d.ClaimCharter(w.ctx, p.ID, nil, "")
	if err != nil || res.Season.Claimable != 0 || len(res.Lines) < 6 {
		t.Fatalf("the free lane's six: %+v %v", res, err)
	}
	if held := w.reload(p.ID).Diamonds; held < 10 {
		t.Fatalf("tier five's diamonds did not arrive: %d", held)
	}

	w.give(p, 900)
	before := w.reload(p.ID).Diamonds
	if _, err := w.d.OpenCharterWithDiamonds(w.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	if got := w.reload(p.ID).Diamonds; got != before-900 {
		t.Fatalf("opening the royal lane cost %d", before-got)
	}
	if _, err := w.d.OpenCharterWithDiamonds(w.ctx, p.ID); !errors.Is(err, service.ErrRoyalOpen) {
		t.Fatalf("opening it twice: %v", err)
	}
	res, err = w.d.ClaimCharter(w.ctx, p.ID, nil, "")
	if err != nil || len(res.Lines) != 6 {
		t.Fatalf("the royal lane's six: %+v %v", res, err)
	}
	var paid int64
	_ = pool.QueryRow(w.ctx, `SELECT coalesce(sum(delta), 0) FROM app.diamond_ledger WHERE player_id = $1 AND reason = 'season'`, p.ID).Scan(&paid)
	if paid != 10+10+15+10+15+10+15 {
		t.Fatalf("the Charter's diamonds in the ledger: %d", paid)
	}

	w.now = w.now.Add(24 * time.Hour)
	w.deeds(p, "raid_wins", 100)
	if s, _ = w.d.GetSeason(w.ctx, p.ID); s.Points != 1600 {
		t.Fatalf("the next day's points: %d", s.Points)
	}
}

// A Charter bought with money opens the lane against its purchase; bought
// again, it pays its diamonds; refunded, the lane closes and what it paid goes.
func TestABoughtCharterAndItsRefund(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	del, id := s.buy(p, "season.pass")
	if len(del.Lines) == 0 || !strings.Contains(del.Lines[0].Text, "royal lane") {
		t.Fatalf("the Charter delivered: %+v", del.Lines)
	}
	season, _ := s.d.GetSeason(s.ctx, p.ID)
	if !season.Royal {
		t.Fatal("the bought Charter left the lane shut")
	}
	s.deeds(p, "raid_wins", 60)
	if _, err := s.d.ClaimCharter(s.ctx, p.ID, nil, ""); err != nil {
		t.Fatal(err)
	}
	var royalPaid int64
	_ = pool.QueryRow(s.ctx, `SELECT coalesce(sum(delta), 0) FROM app.diamond_ledger
		WHERE player_id = $1 AND reason = 'season_royal' AND ref_id = $2 AND class = 'purchased'`, p.ID, id).Scan(&royalPaid)
	if royalPaid != 10+15+10+15+10+15 {
		t.Fatalf("the royal lane's diamonds against the purchase: %d", royalPaid)
	}

	held := s.reload(p.ID).Diamonds
	again, _ := s.buy(p, "season.pass")
	if got := s.reload(p.ID).Diamonds; got != held+900 || len(again.Lines) < 2 {
		t.Fatalf("a second Charter this season paid %d: %+v", got-held, again.Lines)
	}

	signed, _ := s.txn(p, "season.pass", id, map[string]any{"transactionId": id})
	s.notify(iap.NotifyRefund, "", signed)
	p = s.reload(p.ID)
	season, _ = s.d.GetSeason(s.ctx, p.ID)
	if season.Royal || p.Diamonds != held+900-royalPaid {
		t.Fatalf("after the refund: royal %v, %d diamonds (want %d)", season.Royal, p.Diamonds, held+900-royalPaid)
	}
}

// The week's board pays its places when the week turns, level lords sharing
// a place, once.
func TestTheWeeksBoardPaysWhenItCloses(t *testing.T) {
	w := newWorld(t)
	epoch, _ := time.Parse("2006-01-02", w.d.Config.LiveOps.Season.Epoch)
	week := epoch.AddDate(0, 0, 14).Add(12 * time.Hour)
	w.now = week
	first, second, level := w.player(10, 0), w.player(10, 0), w.player(10, 0)
	w.deeds(first, "raid_wins", 1_000_000)
	w.deeds(second, "raid_wins", 999_999)
	w.deeds(level, "raid_wins", 999_999)
	if err := w.d.RefreshLeaderboards(w.ctx); err != nil {
		t.Fatal(err)
	}
	v, err := w.d.GetLeaderboard(w.ctx, first.ID, "week_raids")
	if err != nil {
		t.Fatal(err)
	}
	if v.Period != service.PeriodWeek || len(v.Rows) < 3 || v.Rows[0].Value != 1_000_000 || v.MyRank != 1 ||
		v.Rows[1].Rank != 2 || v.Rows[2].Rank != 2 || len(v.Rewards) != 4 || len(v.Boards) != 11 || v.EndsIn <= 0 {
		t.Fatalf("the week's board: %+v", v)
	}

	w.now = week.AddDate(0, 0, 7)
	w.runJob("boards_close")
	w.runJob("boards_close")
	if m := w.letters(first, "board:week_raids:"); len(m) != 1 || !strings.Contains(m[0].Title, "1st place") ||
		m[0].Grant.Diamonds != 50 {
		t.Fatalf("first place: %+v", m)
	}
	for _, p := range []sqlcdb.AppPlayer{second, level} {
		if m := w.letters(p, "board:week_raids:"); len(m) != 1 || !strings.Contains(m[0].Title, "2nd place") ||
			m[0].Grant.Diamonds != 30 {
			t.Fatalf("a shared second place: %+v", m)
		}
	}
}

// A season's close pays its renown, names its nobles for the season after,
// and sends each lord what their Charter still held.
func TestASeasonClosesWithItsNobility(t *testing.T) {
	w := newWorld(t)
	sc := w.d.Config.LiveOps.Season
	s1 := liveops.SeasonNumbered(sc, 1)
	w.now = s1.Start.Add(20 * 24 * time.Hour)
	emperor, prince := w.player(20, 0), w.player(20, 0)
	for _, x := range []struct {
		p      sqlcdb.AppPlayer
		points int64
	}{{emperor, 90_000}, {prince, 80_000}} {
		if err := w.q.AddSeasonPoints(w.ctx, sqlcdb.AddSeasonPointsParams{PlayerID: x.p.ID, Season: 1,
			Add: x.points * 1000, Cap: x.points * 1000, Day: 21, Now: w.now, Might: x.p.Might}); err != nil {
			t.Fatal(err)
		}
	}
	// Their armies grew during the season: the Might-gained board ranks it.
	w.exec(`UPDATE app.players SET might = might + 5000 WHERE id = $1`, emperor.ID)
	w.exec(`UPDATE app.players SET might = might + 3000 WHERE id = $1`, prince.ID)
	if err := w.d.RefreshLeaderboards(w.ctx); err != nil {
		t.Fatal(err)
	}
	if v, err := w.d.GetLeaderboard(w.ctx, emperor.ID, "season_might"); err != nil || v.MyRank != 1 || v.MyValue != 5000 ||
		v.Period != service.PeriodSeason {
		t.Fatalf("the Might gained this season: %+v %v", v, err)
	}

	w.now = liveops.SeasonNumbered(sc, 2).Start.Add(time.Hour)
	w.runJob("boards_close")
	w.runJob("boards_close")
	if m := w.letters(prince, "board:season_might:1"); len(m) != 1 || !strings.Contains(m[0].Title, "2nd place") ||
		m[0].Grant.Diamonds != 60 || !strings.Contains(m[0].Body, "3,000 Might gained") {
		t.Fatalf("the Might gained's second place: %+v", m)
	}
	if m := w.letters(emperor, "board:season_renown:1"); len(m) != 1 || m[0].Grant.Diamonds != 150 {
		t.Fatalf("the season's first renown: %+v", m)
	}
	if m := w.letters(emperor, "nobility:1"); len(m) != 1 || !strings.Contains(m[0].Title, "Emperor") {
		t.Fatalf("the Emperor's letter: %+v", m)
	}
	if m := w.letters(prince, "nobility:1"); len(m) != 1 || !strings.Contains(m[0].Title, "Prince") {
		t.Fatalf("the Prince's letter: %+v", m)
	}
	var until time.Time
	if err := pool.QueryRow(w.ctx, `SELECT expires_at FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = 'frame_noble_emperor'`,
		emperor.ID).Scan(&until); err != nil || !until.Equal(liveops.SeasonNumbered(sc, 2).End) {
		t.Fatalf("the Emperor's frame is held until %v (%v); want the second season's end", until, err)
	}
	m := w.letters(emperor, "charter:1:left")
	if len(m) != 1 || len(m[0].Grant.Items) == 0 || m[0].Grant.Diamonds != 170 {
		t.Fatalf("what the Charter still held: %+v", m)
	}
	row, _ := w.q.GetPlayerSeason(w.ctx, sqlcdb.GetPlayerSeasonParams{PlayerID: emperor.ID, Season: 1})
	if uint64(row.FreeClaimed) != 1<<50-1 {
		t.Fatalf("the free lane after the close: %b", row.FreeClaimed)
	}
}

// The deeds: counted from before their counters began, claimed tier by tier,
// the fourth with its title.
func TestDeedsAreCountedAndClaimed(t *testing.T) {
	w := newWorld(t)
	p, foe := w.player(12, 0), w.player(12, 0)
	for i := 0; i < 12; i++ {
		w.exec(`INSERT INTO app.battles (attacker_id, defender_id, seed, config_version, attacker_won, rounds,
		        attacker_might, defender_might, gold_stolen, replay) VALUES ($1, $2, 1, 1, true, 3, 10, 10, 50, '{}')`, p.ID, foe.ID)
	}
	w.runJob("deeds_backfill")
	v, err := w.d.GetAchievements(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	find := func(v *service.AchievementsView, id string) service.AchievementView {
		for _, a := range v.Achievements {
			if a.ID == id {
				return a
			}
		}
		t.Fatalf("no deed %s", id)
		return service.AchievementView{}
	}
	if a := find(v, "raider"); a.Progress != 12 || a.Reached != 1 || a.Claimable != 1 || a.Next != 100 {
		t.Fatalf("raids from before the counters: %+v", a)
	}
	if a := find(v, "iron_wall"); a.Progress != 0 {
		t.Fatalf("won raids counted as defences held: %+v", a)
	}
	// Twenty-eight since Wave 6: the Champion and the Headhunter (Rekabet),
	// then the Open-Handed and Shoulder to Shoulder (Sosyal).
	if len(v.Achievements) != 28 || len(v.Categories) != 7 || v.Claimable < 2 {
		t.Fatalf("the page: %d deeds, %d categories, %d to claim", len(v.Achievements), len(v.Categories), v.Claimable)
	}
	if b, _ := w.d.GetBadges(w.ctx, p.ID); b.Achievements != v.Claimable {
		t.Fatalf("the badge says %d, the page %d", b.Achievements, v.Claimable)
	}
	res, err := w.d.ClaimAchievements(w.ctx, p.ID, "raider")
	if err != nil || find(res.Achievements, "raider").Medal != "bronze" {
		t.Fatalf("claiming the raider: %+v %v", res, err)
	}
	if _, err := w.d.ClaimAchievements(w.ctx, p.ID, "raider"); !errors.Is(err, service.ErrDeedsEmpty) {
		t.Fatalf("claiming it again: %v", err)
	}
	if _, err := w.d.ClaimAchievements(w.ctx, p.ID, "no_such_deed"); !errors.Is(err, service.ErrNotFound) {
		t.Fatalf("a deed there is not: %v", err)
	}
	w.exec(`UPDATE app.players SET level = 60 WHERE id = $1`, p.ID)
	held := w.reload(p.ID).Diamonds
	if _, err := w.d.ClaimAchievements(w.ctx, p.ID, "rising_star"); err != nil {
		t.Fatal(err)
	}
	if got := w.reload(p.ID).Diamonds - held; got != 5+10+20+40 {
		t.Fatalf("four tiers paid %d", got)
	}
	var owned bool
	_ = pool.QueryRow(w.ctx, `SELECT EXISTS (SELECT 1 FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = 'title_ach_rising_star')`, p.ID).Scan(&owned)
	if !owned {
		t.Fatal("the fourth tier's title did not arrive")
	}
}
