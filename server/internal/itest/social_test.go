//go:build integration

package itest

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// hall seats a lord in a kingdom of its own and lets them speak.
func hall(w *world, level int32, gold int64) (sqlcdb.AppPlayer, uuid.UUID) {
	w.t.Helper()
	p := w.player(level, gold)
	var id uuid.UUID
	if err := pool.QueryRow(w.ctx,
		`INSERT INTO app.kingdoms (name, tag) VALUES ($1,$2) RETURNING id`,
		"Hall"+uuid.NewString()[:8], uuid.NewString()[:4]).Scan(&id); err != nil {
		w.t.Fatal(err)
	}
	w.exec(`UPDATE app.players SET kingdom_id = $2, kingdom_role = 'king', kingdom_joined_at = $4,
	        chat_rules_version = $3 WHERE id = $1`,
		p.ID, id, w.d.Config.Social.Chat.RulesVersion, w.now)
	return w.reload(p.ID), id
}

// seatIn puts another lord in an existing hall.
func seatIn(w *world, room uuid.UUID, level int32, gold int64) sqlcdb.AppPlayer {
	w.t.Helper()
	p := w.player(level, gold)
	w.exec(`UPDATE app.players SET kingdom_id = $2, kingdom_role = 'member', kingdom_joined_at = $4,
	        chat_rules_version = $3 WHERE id = $1`,
		p.ID, room, w.d.Config.Social.Chat.RulesVersion, w.now)
	return w.reload(p.ID)
}

// The hall's three gates, in the order a lord meets them: the rules, the
// silence, and the filter.
func TestTheHallIsShutUntilTheRulesAreRead(t *testing.T) {
	w := newWorld(t)
	p, _ := hall(w, 10, 1000)
	w.exec(`UPDATE app.players SET chat_rules_version = 0 WHERE id = $1`, p.ID)

	if _, err := w.d.SendChat(w.ctx, p.ID, "hello the hall"); !errors.Is(err, service.ErrRulesUnread) {
		t.Fatalf("a lord who has not read the rules said a line: %v", err)
	}
	// The view says so by carrying the rules, which is what opens the page.
	v, err := w.d.GetChat(w.ctx, p.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if v.Rules == nil || v.Rules.Title == "" || len(v.Rules.Lines) < 3 || v.Rules.Support == "" {
		t.Fatalf("the hall did not offer its rules: %+v", v.Rules)
	}
	if _, err := w.d.AcceptChatRules(w.ctx, p.ID, v.Rules.Version); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.SendChat(w.ctx, p.ID, "hello the hall"); err != nil {
		t.Fatalf("after agreeing, a line was still refused: %v", err)
	}
	v, err = w.d.GetChat(w.ctx, p.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if v.Rules != nil {
		t.Error("the hall is still asking a lord who has agreed")
	}
}

// A blocked word is never said, costs a strike, and the third strike shuts the
// hall for an hour. The punishment is TIME: nothing in the purse moves.
func TestThreeBlockedWordsShutTheHall(t *testing.T) {
	w := newWorld(t)
	p, _ := hall(w, 10, 5000)
	before := w.reload(p.ID)

	for i := range 2 {
		if _, err := w.d.SendChat(w.ctx, p.ID, "you nigger"); !errors.Is(err, service.ErrLineRefused) {
			t.Fatalf("blocked line %d: %v", i+1, err)
		}
		// Past the burst the bucket bites, so time moves between lines.
		w.now = w.now.Add(10 * time.Second)
	}
	if _, err := w.d.SendChat(w.ctx, p.ID, "you nigger"); !errors.Is(err, service.ErrMuted) {
		t.Fatalf("the third blocked word did not shut the hall: %v", err)
	}
	after := w.reload(p.ID)
	if after.Gold != before.Gold || after.Diamonds != before.Diamonds {
		t.Errorf("a silence cost money: gold %d -> %d, diamonds %d -> %d",
			before.Gold, after.Gold, before.Diamonds, after.Diamonds)
	}
	if after.ChatMutedUntil == nil || !after.ChatMutedUntil.After(w.now) {
		t.Fatalf("the hall is not shut: %v", after.ChatMutedUntil)
	}
	// And an ordinary line is refused while it is shut.
	if _, err := w.d.SendChat(w.ctx, p.ID, "I am sorry"); !errors.Is(err, service.ErrMuted) {
		t.Errorf("a muted lord said a line: %v", err)
	}
	// The trail the panel reads is written with the guard.
	var mutes int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.chat_mutes WHERE player_id = $1`, p.ID).
		Scan(&mutes); err != nil {
		t.Fatal(err)
	}
	if mutes != 1 {
		t.Errorf("%d mutes were recorded, want 1", mutes)
	}
}

// An ordinary swear is starred out and costs nothing.
func TestAMaskedWordIsSaidAndCostsNothing(t *testing.T) {
	w := newWorld(t)
	p, _ := hall(w, 10, 1000)
	said, err := w.d.SendChat(w.ctx, p.ID, "that shit hurt")
	if err != nil {
		t.Fatal(err)
	}
	if !said.Masked || strings.Contains(strings.ToLower(said.Line.Body), "shit") {
		t.Fatalf("the line came out as %q (masked=%v)", said.Line.Body, said.Masked)
	}
	if got := w.reload(p.ID); got.ChatStrikes != 0 {
		t.Errorf("a masked word cost %d strikes", got.ChatStrikes)
	}
	// What was TYPED is what the queue reads, not what the hall shows.
	var body string
	if err := pool.QueryRow(w.ctx, `SELECT body FROM app.chat_messages WHERE id = $1`, said.Line.ID).
		Scan(&body); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body, "shit") {
		t.Errorf("the queue reads %q, which is not what was typed", body)
	}
}

// Three lords reporting one line hide it from the room -- and the lord who said
// it still sees it, so nobody is left wondering where their line went.
func TestThreeReportsHideALineFromTheRoom(t *testing.T) {
	w := newWorld(t)
	speaker, room := hall(w, 10, 1000)
	said, err := w.d.SendChat(w.ctx, speaker.ID, "a line somebody dislikes")
	if err != nil {
		t.Fatal(err)
	}
	mid := uuid.MustParse(said.Line.ID)

	for i := range w.d.Config.Social.Chat.ReportsToHide {
		other := seatIn(w, room, 10, 1000)
		if err := w.d.ReportChat(w.ctx, other.ID, mid, "abuse"); err != nil {
			t.Fatalf("report %d: %v", i+1, err)
		}
		// Each reporter is a different lord, so the cooldown is per lord and
		// does not bite here.
	}
	// The room no longer sees it.
	reader := seatIn(w, room, 10, 1000)
	v, err := w.d.GetChat(w.ctx, reader.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range v.Lines {
		if l.ID == said.Line.ID {
			t.Fatal("a hidden line is still in the room")
		}
	}
	// Its author does.
	mine, err := w.d.GetChat(w.ctx, speaker.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, l := range mine.Lines {
		if l.ID == said.Line.ID {
			found, _ = true, l
			if !l.Hidden {
				t.Error("the author's own hidden line is not marked hidden")
			}
		}
	}
	if !found {
		t.Error("the author cannot see their own hidden line")
	}
}

// A block stops everything, both ways, and is never announced to the lord who
// was blocked.
func TestABlockIsTotalAndSilent(t *testing.T) {
	w := newWorld(t)
	me, room := hall(w, 10, 1000)
	them := seatIn(w, room, 10, 1000)

	said, err := w.d.SendChat(w.ctx, them.ID, "a line from a lord you will block")
	if err != nil {
		t.Fatal(err)
	}
	if err := w.d.BlockLord(w.ctx, me.ID, them.ID); err != nil {
		t.Fatal(err)
	}
	v, err := w.d.GetChat(w.ctx, me.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range v.Lines {
		if l.ID == said.Line.ID {
			t.Error("a blocked lord's line is still in the hall")
		}
	}
	// Their page is gone, and the answer is "no such lord" rather than "you
	// are blocked".
	if _, err := w.d.GetRival(w.ctx, me.ID, them.ID); !errors.Is(err, service.ErrNotFound) {
		t.Errorf("a blocked lord's page answered %v", err)
	}
	if _, err := w.d.RequestFriend(w.ctx, them.ID, me.Username); !errors.Is(err, service.ErrNotFound) {
		t.Errorf("the blocked lord could still ask: %v", err)
	}
	// And the blocked lord's own hall is unchanged: a block is one lord's
	// choice, not a punishment the realm carries out.
	theirs, err := w.d.GetChat(w.ctx, them.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(theirs.Lines) == 0 {
		t.Error("the blocked lord lost their own hall")
	}
}

// The friendship, the gift, and the two leashes on it.
func TestAGiftIsAFlaskAndTheDayHasThreeOfThem(t *testing.T) {
	w := newWorld(t)
	a := w.player(20, 1000)
	b := w.player(20, 1000)
	// Both a day old, and friends since yesterday: the two age leashes.
	old := w.now.Add(-48 * time.Hour)
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1 OR id = $3`, a.ID, old, b.ID)
	w.exec(`INSERT INTO app.friends (a, b, since) VALUES (LEAST($1::uuid,$2::uuid), GREATEST($1::uuid,$2::uuid), $3)`,
		a.ID, b.ID, old)

	if _, err := w.d.SendGift(w.ctx, a.ID, b.ID); err != nil {
		t.Fatalf("sending a gift: %v", err)
	}
	if _, err := w.d.SendGift(w.ctx, a.ID, b.ID); !errors.Is(err, service.ErrGiftSentToday) {
		t.Errorf("a second gift the same day: %v", err)
	}

	// Spend the taker's pool so a draught has somewhere to go.
	w.exec(`UPDATE app.players SET energy_milli = 1000, energy_updated_at = $2 WHERE id = $1`, b.ID, w.now)
	before := w.reload(b.ID)
	took, err := w.d.TakeGift(w.ctx, b.ID, a.ID, before.ActionSeq+1)
	if err != nil {
		t.Fatalf("taking a gift: %v", err)
	}
	if took.EnergyGained <= 0 {
		t.Errorf("the draught restored %d", took.EnergyGained)
	}
	// It is a FLASK: a share of the TAKER's pool, not a flat number and not
	// the sender's.
	eff := w.reload(b.ID)
	want := int64(float64(economy.MaxEnergy(w.d.Config, int64(eff.Level), int64(eff.StatEnergy), 0)) *
		float64(w.d.Config.Token(w.d.Config.Social.Friends.GiftToken).EnergyPct) / 100)
	if took.EnergyGained != want {
		t.Errorf("the draught gave %d, want a %d%% share of the pool: %d", took.EnergyGained,
			w.d.Config.Token(w.d.Config.Social.Friends.GiftToken).EnergyPct, want)
	}
	if _, err := w.d.TakeGift(w.ctx, b.ID, a.ID, eff.ActionSeq+1); !errors.Is(err, service.ErrGiftNone) {
		t.Errorf("the same gift was taken twice: %v", err)
	}
}

// A friendship a day old is what carries a gift; a fresh one carries nothing.
func TestAFreshFriendshipCarriesNoGift(t *testing.T) {
	w := newWorld(t)
	a := w.player(20, 1000)
	b := w.player(20, 1000)
	w.exec(`UPDATE app.players SET created_at = $2 WHERE id = $1 OR id = $3`,
		a.ID, w.now.Add(-48*time.Hour), b.ID)
	w.exec(`INSERT INTO app.friends (a, b, since) VALUES (LEAST($1::uuid,$2::uuid), GREATEST($1::uuid,$2::uuid), $3)`,
		a.ID, b.ID, w.now)
	if _, err := w.d.SendGift(w.ctx, a.ID, b.ID); !errors.Is(err, service.ErrGiftTooNew) {
		t.Errorf("a fresh friendship sent a gift: %v", err)
	}
	// And an account made this morning sends nothing at all.
	fresh := w.player(20, 1000)
	w.exec(`INSERT INTO app.friends (a, b, since) VALUES (LEAST($1::uuid,$2::uuid), GREATEST($1::uuid,$2::uuid), $3)`,
		fresh.ID, b.ID, w.now.Add(-48*time.Hour))
	if _, err := w.d.SendGift(w.ctx, fresh.ID, b.ID); !errors.Is(err, service.ErrAccountTooNew) {
		t.Errorf("a fresh account sent a gift: %v", err)
	}
}

// The spyglass: gold out, a report in, and the rival is told.
func TestTheSpyglassCostsGoldAndIsFelt(t *testing.T) {
	w := newWorld(t)
	me := w.player(20, 100_000)
	them := w.player(20, 5_000)
	w.exec(`INSERT INTO app.soldiers (player_id, slot_index, type_id, tier, level, name, rolled_config_version)
	        VALUES ($1, 1, 'peasant', 'uncommon', 20, 'A Soldier', 1)`, them.ID)

	// Before: the page has names and ranks, and no numbers.
	page, err := w.d.GetRival(w.ctx, me.ID, them.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Army) != 1 || page.Army[0].Attack != 0 {
		t.Fatalf("an unscouted army showed its numbers: %+v", page.Army)
	}
	if page.Scouted {
		t.Error("a lord who paid nothing holds a report")
	}

	before := w.reload(me.ID)
	cost := w.d.Config.Social.Spy.Cost(int(them.Level))
	got, err := w.d.Spy(w.ctx, me.ID, them.ID, before.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Scouted || got.ScoutedFor <= 0 {
		t.Fatalf("the report is not live: %+v", got)
	}
	if len(got.Army) != 1 || got.Army[0].Attack <= 0 {
		t.Errorf("the report carries no numbers: %+v", got.Army)
	}
	after := w.reload(me.ID)
	if after.Gold != before.Gold-cost {
		t.Errorf("the spyglass cost %d, want %d", before.Gold-after.Gold, cost)
	}
	if sum := goldSum(t, me.ID, "spy"); sum != -cost {
		t.Errorf("the ledger says %d, want %d", sum, -cost)
	}
	// The rival is told, on the page where the raiding is.
	v, err := w.d.GetTargets(w.ctx, them.ID)
	if err != nil {
		t.Fatal(err)
	}
	if v.ScoutedToday != 1 {
		t.Errorf("the rival was told %d times, want 1", v.ScoutedToday)
	}
}

// The kingdom's aid: a stack for the lord who asked, favour for the one who
// answered, and the stack is an ordinary timed boost.
func TestAidStacksOnTheAskerAndPaysTheHelper(t *testing.T) {
	w := newWorld(t)
	asker, room := hall(w, 20, 1000)
	helper := seatIn(w, room, 20, 1000)

	call, err := w.d.AskAid(w.ctx, asker.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.AskAid(w.ctx, asker.ID); !errors.Is(err, service.ErrAidSoon) {
		t.Errorf("a second call straight away: %v", err)
	}
	if _, err := w.d.AnswerAid(w.ctx, asker.ID, uuid.MustParse(call.ID)); !errors.Is(err, service.ErrAidOwn) {
		t.Errorf("a lord answered their own call: %v", err)
	}

	favourBefore := w.reload(helper.ID).KingdomFavour
	given, err := w.d.AnswerAid(w.ctx, helper.ID, uuid.MustParse(call.ID))
	if err != nil {
		t.Fatal(err)
	}
	if given.Favour != w.d.Config.Social.Aid.FavourPerAid {
		t.Errorf("the helper was paid %d favour", given.Favour)
	}
	if got := w.reload(helper.ID).KingdomFavour; got != favourBefore+given.Favour {
		t.Errorf("favour went %d -> %d", favourBefore, got)
	}
	// The stack is two ordinary boost rows, in the timed lanes, with source
	// 'aid' -- which is how they are counted.
	var rows int
	if err := pool.QueryRow(w.ctx,
		`SELECT count(*) FROM app.player_boosts WHERE player_id = $1 AND source = 'aid'`, asker.ID).
		Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Errorf("a stack is %d boost rows, want 2 (gold and experience)", rows)
	}
	// Answering twice does nothing.
	if _, err := w.d.AnswerAid(w.ctx, helper.ID, uuid.MustParse(call.ID)); !errors.Is(err, service.ErrAidGone) {
		t.Errorf("the same call was answered twice: %v", err)
	}
}

// The shared goal reads the counters every action already writes, and a lord
// who did too little of the work cannot claim it.
func TestTheSharedGoalIsFedByOrdinaryPlay(t *testing.T) {
	w := newWorld(t)
	lord, room := hall(w, 20, 1000)
	for range 3 {
		seatIn(w, room, 20, 1000)
	}
	v, err := w.d.GetHelp(w.ctx, lord.ID)
	if err != nil {
		t.Fatal(err)
	}
	if v.Goal == nil {
		t.Fatal("a kingdom of four has no shared goal")
	}
	if v.Goal.Target <= 0 || v.Goal.Members < 4 {
		t.Fatalf("the goal's bar is %+v", v.Goal)
	}
	if v.Goal.Progress != 0 || v.Goal.Mine != 0 {
		t.Fatalf("a fresh goal already has %d on it", v.Goal.Progress)
	}
	// Nobody may claim a bar nobody has moved.
	if _, err := w.d.ClaimGoalChest(w.ctx, lord.ID, 0); !errors.Is(err, service.ErrGoalShort) {
		t.Errorf("an untouched goal paid out: %v", err)
	}

	// Ordinary play: whichever kind the day asked for, the deeds feed it.
	switch v.Goal.Kind {
	case "energy":
		for range 6 {
			if _, err := w.d.Collect(w.ctx, lord.ID, "grapes", w.reload(lord.ID).ActionSeq+1); err != nil {
				t.Fatalf("working: %v", err)
			}
		}
	default:
		// Victories: fed by raids and arena wins, which other tests cover;
		// push the counter the same way the deeds would.
		w.exec(`UPDATE app.kingdom_goals SET progress = target WHERE id = $1`,
			uuid.MustParse(v.Goal.ID))
		w.exec(`INSERT INTO app.kingdom_goal_parts (goal_id, player_id, amount)
		        VALUES ($1, $2, $3)`, uuid.MustParse(v.Goal.ID), lord.ID, v.Goal.Target)
	}
	after, err := w.d.GetHelp(w.ctx, lord.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.Goal.Progress <= 0 {
		t.Fatalf("playing moved the bar to %d", after.Goal.Progress)
	}
}

// A lord who joined after the day began has no share and claims nothing: the
// kingdom-hopping guard, which needs no clock of its own.
func TestAKingdomHopperClaimsNothing(t *testing.T) {
	w := newWorld(t)
	lord, room := hall(w, 20, 1000)
	for range 3 {
		seatIn(w, room, 20, 1000)
	}
	v, err := w.d.GetHelp(w.ctx, lord.ID)
	if err != nil || v.Goal == nil {
		t.Fatalf("no goal: %v", err)
	}
	goal := uuid.MustParse(v.Goal.ID)
	w.exec(`UPDATE app.kingdom_goals SET progress = target WHERE id = $1`, goal)

	hopper := seatIn(w, room, 20, 1000)
	if _, err := w.d.ClaimGoalChest(w.ctx, hopper.ID, 0); !errors.Is(err, service.ErrGoalShare) {
		t.Errorf("a lord who did none of the work claimed a chest: %v", err)
	}
	// And a lord who did the work takes it once.
	w.exec(`INSERT INTO app.kingdom_goal_parts (goal_id, player_id, amount) VALUES ($1,$2,$3)`,
		goal, lord.ID, v.Goal.Target)
	if _, err := w.d.ClaimGoalChest(w.ctx, lord.ID, 0); err != nil {
		t.Fatalf("the lord who did the work was refused: %v", err)
	}
	if _, err := w.d.ClaimGoalChest(w.ctx, lord.ID, 0); !errors.Is(err, service.ErrGoalTaken) {
		t.Errorf("the same chest was taken twice: %v", err)
	}
}

// A lord's own choice about who may open their page is kept.
func TestAPageIsAsPrivateAsItsLordAsked(t *testing.T) {
	w := newWorld(t)
	me := w.player(20, 1000)
	them := w.player(20, 1000)

	if _, err := w.d.SetPrivacyPrefs(w.ctx, them.ID, service.PrivacyPrefs{
		Profile: "friends", Online: false, Requests: false,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.GetRival(w.ctx, me.ID, them.ID); !errors.Is(err, service.ErrRivalHidden) {
		t.Errorf("a friends-only page opened to a stranger: %v", err)
	}
	// Their own page still opens for them.
	if _, err := w.d.GetRival(w.ctx, them.ID, them.ID); err != nil {
		t.Errorf("a lord could not see their own page: %v", err)
	}
	// And they are taking no requests.
	if _, err := w.d.RequestFriend(w.ctx, me.ID, them.Username); !errors.Is(err, service.ErrFriendRefused) {
		t.Errorf("a lord who shut their door took a request: %v", err)
	}
}

// The hall is swept to the balance's own window.
func TestTheHallIsSwept(t *testing.T) {
	w := newWorld(t)
	p, room := hall(w, 10, 1000)
	if _, err := w.d.SendChat(w.ctx, p.ID, "a line that will be swept"); err != nil {
		t.Fatal(err)
	}
	days := w.d.Config.Social.Chat.RetentionDays
	w.exec(`UPDATE app.chat_messages SET created_at = $2 WHERE kingdom_id = $1`,
		room, w.now.AddDate(0, 0, -days-1))
	// The job as the runner would run it, so the sweep is the shipped one.
	var sweep service.Job
	for _, j := range service.ScheduledJobs() {
		if j.Name == "chat_sweep" {
			sweep = j
		}
	}
	if sweep.Run == nil {
		t.Fatal("there is no chat_sweep job")
	}
	if err := sweep.Run(w.ctx, w.d, w.now); err != nil {
		t.Fatalf("sweeping: %v", err)
	}
	var left int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.chat_messages WHERE kingdom_id = $1`, room).
		Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("%d lines survived the sweep", left)
	}
}
