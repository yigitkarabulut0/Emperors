//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/cart"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The Tax Cart: locked below its level, one waiting for a new gate, another
// every four hours, a writ when the yard is empty -- and each cart's prize the
// one the lord and the cart's number fix.
func TestTheTaxCartComesAndOpens(t *testing.T) {
	w := newWorld(t)
	low := w.player(1, 0)
	if _, err := w.d.OpenCart(w.ctx, low.ID); !errors.Is(err, service.ErrCartLocked) {
		t.Fatalf("a level-1 lord opened a cart: %v", err)
	}

	p := w.player(10, 0)
	w.exec(`UPDATE app.players SET cart_at = $2 WHERE id = $1`, p.ID, w.now)
	want := w.d.Config.Retention.Cart.Odds[cart.Draw(game.SeedForString(w.d.ShopSecret, p.ID.String(), 1, 0xCA27),
		w.d.Config.Retention.Cart.Odds)].ID
	res, err := w.d.OpenCart(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Prize != want || len(res.Lines) == 0 || res.Cart.Stock != 0 || res.Cart.Opened != 1 {
		t.Fatalf("the first cart: prize %s (want %s), %d lines, stock %d, opened %d",
			res.Prize, want, len(res.Lines), res.Cart.Stock, res.Cart.Opened)
	}
	if res.Snapshot.Cart.Stock != 0 || res.Snapshot.Cart.NextIn <= 0 {
		t.Fatalf("the snapshot's cart after opening: %+v", res.Snapshot.Cart)
	}
	if _, err := w.d.OpenCart(w.ctx, p.ID); !errors.Is(err, service.ErrCartEmpty) {
		t.Fatalf("an empty yard opened: %v", err)
	}

	// Nine hours on: two carts, and the hour past the second carries.
	w.now = w.now.Add(9 * time.Hour)
	if v, err := w.d.GetCart(w.ctx, p.ID); err != nil || v.Stock != 2 || v.NextIn > 3*3600 || v.NextIn < 3*3600-5 {
		t.Fatalf("nine hours on: %+v %v", v, err)
	}
	for i := 0; i < 2; i++ {
		if _, err := w.d.OpenCart(w.ctx, p.ID); err != nil {
			t.Fatal(err)
		}
	}

	// A writ opens a cart when none is waiting.
	w.exec(`INSERT INTO app.player_tokens (player_id, token, qty) VALUES ($1, 'cart', 1)`, p.ID)
	if res, err := w.d.OpenCart(w.ctx, p.ID); err != nil || res.Cart.Tokens != 0 || res.Cart.Opened != 4 {
		t.Fatalf("with a writ: %+v %v", res, err)
	}
	if n := w.count(`SELECT coalesce(sum(value), 0) FROM app.player_deeds WHERE player_id = $1
		AND deed = 'carts_opened' AND scope = 'life'`, p.ID); n != 4 {
		t.Fatalf("carts opened counted %d; want 4", n)
	}
}

// The calendar: a new lord's first square with a pardon; a broken run refused
// without a mend, mended by a pardon or diamonds, or begun anew.
func TestTheCalendarWalksMendsAndBeginsAnew(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	res, err := w.d.ClaimDaily(w.ctx, p.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Daily.Day != 1 || !res.Daily.ClaimedToday || res.Daily.Pardons != 1 || len(res.Lines) < 2 {
		t.Fatalf("the first square: day %d claimed %v pardons %d lines %v",
			res.Daily.Day, res.Daily.ClaimedToday, res.Daily.Pardons, res.Lines)
	}
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); !errors.Is(err, service.ErrAlreadyClaimed) {
		t.Fatalf("a second claim today: %v", err)
	}
	// And the square SAYS it was taken. It used to stay "today" until tomorrow,
	// so a lord claimed their gift and the tile kept its waiting glow with no
	// seal on it -- the calendar never showed what they had already had.
	got, err := w.d.GetDaily(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Squares) == 0 || got.Squares[0].State != "claimed" {
		t.Fatalf("today's square, once claimed, reads %q",
			func() string {
				if len(got.Squares) == 0 {
					return "<no squares>"
				}
				return got.Squares[0].State
			}())
	}
	if len(got.Squares) > 1 && got.Squares[1].State != "ahead" {
		t.Fatalf("tomorrow's square reads %q", got.Squares[1].State)
	}

	// Two days on: one day missed, the run broken.
	w.now = w.now.Add(48 * time.Hour)
	v, _ := w.d.GetDaily(w.ctx, p.ID)
	if v.Broken == nil || v.Broken.Missed != 1 || v.Broken.RestoreDiamonds != 20 || !v.Broken.CanPardon || v.Day != 2 {
		t.Fatalf("one day missed: %+v", v)
	}
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); !errors.Is(err, service.ErrCalendarBroken) {
		t.Fatalf("an unmended broken run: %v", err)
	}
	if res, err = w.d.ClaimDaily(w.ctx, p.ID, "pardon"); err != nil || res.Daily.Day != 2 || res.Daily.Pardons != 0 {
		t.Fatalf("mended with a pardon: %+v %v", res, err)
	}

	// Three days on: two missed. No pardon, too few diamonds; then with them.
	w.now = w.now.Add(72 * time.Hour)
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, "pardon"); !errors.Is(err, service.ErrNoToken) {
		t.Fatalf("a pardon not held: %v", err)
	}
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, "diamonds"); !errors.Is(err, service.ErrNotEnoughDiamonds) {
		t.Fatalf("mending without the diamonds: %v", err)
	}
	w.exec(`UPDATE app.players SET diamonds = diamonds + 60 WHERE id = $1`, p.ID)
	w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
	        SELECT id, 60, 60, diamonds, 'admin_grant', 'admin' FROM app.players WHERE id = $1`, p.ID)
	before := w.reload(p.ID).Diamonds
	if res, err = w.d.ClaimDaily(w.ctx, p.ID, "diamonds"); err != nil || res.Daily.Day != 3 {
		t.Fatalf("mended with diamonds: %+v %v", res, err)
	}
	if got := w.reload(p.ID).Diamonds; got != before-50+w.d.Config.Retention.Calendar.Squares[2].Grant.Diamonds {
		t.Fatalf("mending two days cost %d diamonds net", before-got)
	}

	// Two days on again, and the lord starts anew.
	w.now = w.now.Add(48 * time.Hour)
	if res, err = w.d.ClaimDaily(w.ctx, p.ID, "anew"); err != nil || res.Daily.Day != 1 || res.Daily.Streak != 1 {
		t.Fatalf("anew: %+v %v", res, err)
	}
	if res.Daily.Pardons != 0 {
		t.Fatalf("a run begun anew gave a pardon: %d", res.Daily.Pardons)
	}
}

// The week's quests: six on the board, the two diamond ones always; a task done
// by the week's deeds is claimed once for its points; a chest opens on them.
func TestTheWeeksQuestsPayTasksAndChests(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	v, err := w.d.GetWeekly(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(v.Tasks) != 6 || v.Tasks[0].ID != "w_days" || v.Tasks[1].ID != "w_dailies" || v.PointsMax != 240 {
		t.Fatalf("the board: %d tasks, first %s %s, %d points", len(v.Tasks), v.Tasks[0].ID, v.Tasks[1].ID, v.PointsMax)
	}
	if _, err := w.d.ClaimWeeklyTask(w.ctx, p.ID, 0); !errors.Is(err, service.ErrQuestUnfinished) {
		t.Fatalf("an unfinished task: %v", err)
	}
	week := w.now.UTC()
	for week.Weekday() != time.Monday {
		week = week.AddDate(0, 0, -1)
	}
	period := time.Date(week.Year(), week.Month(), week.Day(), 0, 0, 0, 0, time.UTC).Unix() / 86400
	w.exec(`INSERT INTO app.player_deeds (player_id, scope, period, deed, value) VALUES
	        ($1, 'week', $2, 'daily_claims', 5), ($1, 'week', $2, 'daily_quests', 12)`, p.ID, period)
	for slot := 0; slot < 2; slot++ {
		res, err := w.d.ClaimWeeklyTask(w.ctx, p.ID, slot)
		if err != nil {
			t.Fatal(err)
		}
		if len(res.Lines) == 0 || res.Weekly.Points != int64(40*(slot+1)) {
			t.Fatalf("task %d paid %v, points %d", slot, res.Lines, res.Weekly.Points)
		}
	}
	if _, err := w.d.ClaimWeeklyTask(w.ctx, p.ID, 0); !errors.Is(err, service.ErrAlreadyClaimed) {
		t.Fatalf("a task claimed twice: %v", err)
	}
	if _, err := w.d.ClaimWeeklyChest(w.ctx, p.ID, 1); !errors.Is(err, service.ErrQuestUnfinished) {
		t.Fatalf("the 160-point chest at 80: %v", err)
	}
	res, err := w.d.ClaimWeeklyChest(w.ctx, p.ID, 0)
	if err != nil || !res.Weekly.Chests[0].Claimed || len(res.Lines) == 0 {
		t.Fatalf("the first chest: %+v %v", res, err)
	}
	if _, err := w.d.ClaimWeeklyChest(w.ctx, p.ID, 0); !errors.Is(err, service.ErrAlreadyClaimed) {
		t.Fatalf("a chest opened twice: %v", err)
	}
	b, _ := w.d.GetBadges(w.ctx, p.ID)
	if b.Weekly != 0 {
		t.Fatalf("the weekly badge with nothing waiting: %d", b.Weekly)
	}
}

// The Golden Hour: a run that spends its share of the pool lights it, and the
// collects after pay more gold -- ledgered on its own row, never predicted.
func TestTheGoldenHourLightsAndPays(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	snap, err := w.d.GetState(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	max := snap.Energy.Max
	w.exec(`UPDATE app.players SET energy_milli = $2 WHERE id = $1`, p.ID, max*1000)
	var job string
	var cost int64
	for _, j := range w.d.Config.Jobs.Jobs {
		if j.UnlockLevel <= 10 {
			job, cost = j.ID, j.EnergyCost
		}
	}
	need := (max*w.d.Config.Retention.Frenzy.FillPct/100 + cost - 1) / cost
	ids := make([]string, need)
	for i := range ids {
		ids[i] = job
	}
	res, err := w.d.CollectBatch(w.ctx, p.ID, ids, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if !res.FrenzyStarted || res.FrenzyGold != 0 || !res.Snapshot.Frenzy.Active {
		t.Fatalf("the run that lights it: started %v gold %d frenzy %+v", res.FrenzyStarted, res.FrenzyGold, res.Snapshot.Frenzy)
	}
	seq := res.AppliedThrough
	w.now = w.now.Add(5 * time.Second)
	more, err := w.d.CollectBatch(w.ctx, p.ID, []string{job, job}, seq+1)
	if err != nil {
		t.Fatal(err)
	}
	if more.FrenzyGold <= 0 || more.FrenzyGold >= more.GoldGained {
		t.Fatalf("covered collects: %d of %d gold from the Golden Hour", more.FrenzyGold, more.GoldGained)
	}
	if n := w.count(`SELECT count(*) FROM app.gold_ledger WHERE player_id = $1 AND reason = 'golden_hour'`, p.ID); n != 1 {
		t.Fatalf("golden hour ledger rows: %d", n)
	}
	// A minute on it has burned out, and the day has two left.
	w.now = w.now.Add(time.Minute)
	snap, _ = w.d.GetState(w.ctx, p.ID)
	if snap.Frenzy.Active || snap.Frenzy.Used != 1 || snap.Frenzy.ReadyIn <= 0 {
		t.Fatalf("after the hour: %+v", snap.Frenzy)
	}
}

// The Victory Road: a level-12 lord claims the five milestones behind them at
// once, and then there is nothing to claim.
func TestTheVictoryRoadPaysWhatIsBehind(t *testing.T) {
	w := newWorld(t)
	p := w.player(12, 0)
	v, err := w.d.GetRoad(w.ctx, p.ID)
	if err != nil || v.Claimable != 5 || v.DiamondsTotal != 435 || len(v.Milestones) != 15 {
		t.Fatalf("the road at 12: %+v %v", v, err)
	}
	one := 1
	if _, err := w.d.ClaimRoad(w.ctx, p.ID, &one); err != nil {
		t.Fatal(err)
	}
	res, err := w.d.ClaimRoad(w.ctx, p.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.Road.Claimable != 0 || w.reload(p.ID).Diamonds != 10+15+20+25+20 {
		t.Fatalf("after claiming: %d claimable, %d diamonds", res.Road.Claimable, w.reload(p.ID).Diamonds)
	}
	if _, err := w.d.ClaimRoad(w.ctx, p.ID, nil); !errors.Is(err, service.ErrRoadEmpty) {
		t.Fatalf("claiming an empty road: %v", err)
	}
	far := 14
	if _, err := w.d.ClaimRoad(w.ctx, p.ID, &far); !errors.Is(err, service.ErrRoadEmpty) {
		t.Fatalf("claiming level 60 at 12: %v", err)
	}
}

// The guide: a new lord's steps done by doing them, the steward's purse on the
// market step, Karel beaten in a real fight, the Heir's frame at the end.
func TestTheGuideWalksANewLord(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	snap, err := w.d.GetState(w.ctx, p.ID)
	if err != nil || !snap.Guide.Active || snap.Guide.Step != "welcome" || !snap.Guide.Ready || snap.Guide.Count != 12 {
		t.Fatalf("a new lord's guide: %+v %v", snap.Guide, err)
	}
	if _, err := w.d.AdvanceGuide(w.ctx, p.ID, "first_collect"); !errors.Is(err, service.ErrGuideMoved) {
		t.Fatalf("advancing a step the lord is not on: %v", err)
	}
	adv, err := w.d.AdvanceGuide(w.ctx, p.ID, "welcome")
	if err != nil || adv.Guide.Step != "first_collect" || adv.Guide.Ready {
		t.Fatalf("after welcome: %+v %v", adv, err)
	}
	if _, err := w.d.AdvanceGuide(w.ctx, p.ID, "first_collect"); !errors.Is(err, service.ErrGuideNotReady) {
		t.Fatalf("a step not done: %v", err)
	}
	if _, err := w.d.Collect(w.ctx, p.ID, w.d.Config.Jobs.Jobs[0].ID, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	if adv, err = w.d.AdvanceGuide(w.ctx, p.ID, "first_collect"); err != nil || adv.Guide.Step != "reach_2" {
		t.Fatalf("after the first collect: %+v %v", adv, err)
	}

	// The step before the market, done: entering the market pays the purse.
	cartStep := w.d.Config.Retention.Guide.GuideStepIndex("cart")
	w.exec(`UPDATE app.players SET guide_step = $2, level = 3, gold = 0 WHERE id = $1`, p.ID, cartStep)
	w.exec(`INSERT INTO app.player_deeds (player_id, scope, period, deed, value) VALUES ($1, 'life', 0, 'carts_opened', 1)`, p.ID)
	if adv, err = w.d.AdvanceGuide(w.ctx, p.ID, "cart"); err != nil || adv.Guide.Step != "buy_gear" {
		t.Fatalf("into the market: %+v %v", adv, err)
	}
	gold := w.reload(p.ID).Gold
	if len(adv.Lines) != 1 || gold <= 0 || gold > w.d.Config.Retention.Guide.PurseMax {
		t.Fatalf("the steward's purse: %v, %d gold", adv.Lines, gold)
	}

	// Karel the Bandit, with a soldier-less lord at level 5.
	bandit := w.d.Config.Retention.Guide.GuideStepIndex("bandit")
	w.exec(`UPDATE app.players SET guide_step = $2, level = 5 WHERE id = $1`, p.ID, bandit)
	snap, _ = w.d.GetState(w.ctx, p.ID)
	if snap.Guide.Bandit == nil || snap.Guide.Bandit.Might <= 0 || snap.Guide.Bandit.Purse <= 0 {
		t.Fatalf("the bandit's card: %+v", snap.Guide.Bandit)
	}
	fight, err := w.d.FightBandit(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !fight.Won || fight.Replay == nil || fight.Gold <= 0 || fight.Guide.Step != "farewell" {
		t.Fatalf("the fight: won %v gold %d step %s", fight.Won, fight.Gold, fight.Guide.Step)
	}
	if _, err := w.d.FightBandit(w.ctx, p.ID); !errors.Is(err, service.ErrGuideMoved) {
		t.Fatalf("a second fight: %v", err)
	}
	fin, err := w.d.AdvanceGuide(w.ctx, p.ID, "farewell")
	if err != nil || fin.Guide.Active || len(fin.Lines) != 2 {
		t.Fatalf("the finish: %+v %v", fin, err)
	}
	if n := w.count(`SELECT count(*) FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = 'frame_heir'`, p.ID); n != 1 {
		t.Fatalf("the Heir's frame: %d", n)
	}

	// Another lord skips.
	q := w.player(1, 0)
	if sk, err := w.d.SkipGuide(w.ctx, q.ID); err != nil || sk.Guide.Active {
		t.Fatalf("a skip: %+v %v", sk, err)
	}
}

// Welcome back: a lord away three days gets one letter, not two; past fourteen
// days a second; a lord seen yesterday none.
func TestWelcomeBackWritesOncePerAbsence(t *testing.T) {
	w := newWorld(t)
	away, here := w.player(10, 0), w.player(10, 0)
	w.exec(`UPDATE app.players SET last_seen_at = $2 WHERE id = $1`, away.ID, w.now.Add(-4*24*time.Hour))
	w.exec(`UPDATE app.players SET last_seen_at = $2 WHERE id = $1`, here.ID, w.now.Add(-24*time.Hour))
	letters := func(id any) int {
		return w.count(`SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = 'winback'`, id)
	}
	for i := 0; i < 2; i++ {
		if err := w.d.DevRunJob(w.ctx, "winback"); err != nil {
			t.Fatal(err)
		}
	}
	if letters(away.ID) != 1 || letters(here.ID) != 0 {
		t.Fatalf("after two runs: %d letters for the lord away, %d for the one here", letters(away.ID), letters(here.ID))
	}
	w.now = w.now.Add(11 * 24 * time.Hour)
	if err := w.d.DevRunJob(w.ctx, "winback"); err != nil {
		t.Fatal(err)
	}
	if letters(away.ID) != 2 {
		t.Fatalf("fifteen days away: %d letters", letters(away.ID))
	}
	claim, err := w.d.ClaimAllMail(w.ctx, away.ID)
	if err != nil || len(claim.Claimed) != 2 {
		t.Fatalf("claiming the welcome: %+v %v", claim, err)
	}
	snap, _ := w.d.GetState(w.ctx, away.ID)
	if snap.Cart.Tokens != 1 {
		t.Fatalf("the welcome's writ: %d", snap.Cart.Tokens)
	}
}

// A flask restores its share of the pool, not past it; a full pool refuses
// it, and it moves action_seq as the lord's own action.
func TestAFlaskRestoresItsShare(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	w.exec(`UPDATE app.players SET energy_milli = 0 WHERE id = $1`, p.ID)
	w.exec(`INSERT INTO app.player_tokens (player_id, token, qty) VALUES ($1, 'flask_small', 2)`, p.ID)
	snap, _ := w.d.GetState(w.ctx, p.ID)
	if _, err := w.d.UseToken(w.ctx, p.ID, "pardon", p.ActionSeq+1); !errors.Is(err, service.ErrNotUsable) {
		t.Fatalf("drinking a pardon: %v", err)
	}
	res, err := w.d.UseToken(w.ctx, p.ID, "flask_small", p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	want := snap.Energy.Max * w.d.Config.Token("flask_small").EnergyPct / 100
	if res.EnergyGained != want || res.Snapshot.Player.ActionSeq != p.ActionSeq+1 {
		t.Fatalf("a small flask gave %d (want %d), seq %d", res.EnergyGained, want, res.Snapshot.Player.ActionSeq)
	}
	w.exec(`UPDATE app.players SET energy_milli = $2 WHERE id = $1`, p.ID, snap.Energy.Max*1000)
	if _, err := w.d.UseToken(w.ctx, p.ID, "flask_small", p.ActionSeq+2); !errors.Is(err, service.ErrEnergyFull) {
		t.Fatalf("a flask for a full pool: %v", err)
	}
}

// A Tax Cart's Lucky Charm is a luck bonus that lasts its hour: the market
// rolled while it burns is stamped with it, and one rolled after is not.
func TestALuckyCharmTiltsTheMarketForItsHour(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	w.exec(`INSERT INTO app.player_boosts (player_id, bucket, amount_bp, starts_at, expires_at, source)
	        VALUES ($1, 'luck_bp', 2500, $2, $3, 'cart')`, p.ID, w.now.Add(-time.Minute), w.now.Add(time.Hour))
	w.exec(`UPDATE app.players SET boost_until = $2 WHERE id = $1`, p.ID, w.now.Add(time.Hour))
	luck := func() int {
		if _, err := w.d.GetShop(w.ctx, p.ID); err != nil {
			t.Fatal(err)
		}
		return w.count(`SELECT luck_bp FROM app.shop_state WHERE player_id = $1`, p.ID)
	}
	if got := luck(); got != 2500 {
		t.Fatalf("the market rolled under a charm at %d bp of luck; want 2500", got)
	}
	w.now = w.now.Add(2 * time.Hour)
	if got := luck(); got != 0 {
		t.Fatalf("the market rolled after the charm at %d bp", got)
	}
}
