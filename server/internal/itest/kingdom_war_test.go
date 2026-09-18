//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/boss"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Krallik Boss ve Savaslari (Wave 8), end to end: the kingdom's beast and the
// kingdom's wars, against a real database.

// muster seats n lords in a kingdom of their own and gives each of them
// something to fight with, so the kingdom's Might is a number a beast can be
// cut from. It returns the hall and its lords, reloaded with their Might
// cached.
func muster(w *world, n int, level int32) (uuid.UUID, []sqlcdb.AppPlayer) {
	w.t.Helper()
	first, room := hall(w, level, 0)
	lords := []sqlcdb.AppPlayer{first}
	for i := 1; i < n; i++ {
		lords = append(lords, seatIn(w, room, level, 0))
	}
	for i, p := range lords {
		// A hero worth swinging: stat points a lord of this level would have
		// spent. Without them the whole kingdom is worth nothing and the beast's
		// wall is nothing either, which proves nothing.
		w.exec(`UPDATE app.players SET stat_attack = 60, stat_defense = 40 WHERE id = $1`, p.ID)
		// GetArmy is what caches Might on the row, and every muster in this
		// feature reads that cached figure.
		if _, err := w.d.GetArmy(w.ctx, p.ID); err != nil {
			w.t.Fatal(err)
		}
		lords[i] = w.reload(p.ID)
		if lords[i].Might <= 0 {
			w.t.Fatalf("lord %d is worth nothing, so nothing below can be measured", i)
		}
	}
	return room, lords
}

func kingdomMight(lords []sqlcdb.AppPlayer) int64 {
	var sum int64
	for _, p := range lords {
		sum += p.Might
	}
	return sum
}

// standingBoss is the beast in front of a kingdom, or a failed test.
func standingBoss(w *world, room uuid.UUID) sqlcdb.AppKingdomBoss {
	w.t.Helper()
	row, err := w.q.GetKingdomBoss(w.ctx, room)
	if err != nil {
		w.t.Fatalf("no beast stands against the kingdom: %v", err)
	}
	return row
}

// One beast per kingdom, and one cycle per window.
//
// The window is the rule, not the beast's health: a kingdom that puts one down
// in an hour waits out the forty-eight hours all the same, or the cycle would
// be a cycle only for the kingdoms too weak to break it.
func TestABeastRisesOncePerKingdomPerWindow(t *testing.T) {
	w := newWorld(t)
	room, lords := muster(w, 3, 30)

	w.runJob("boss_cycle")
	w.runJob("boss_cycle")
	if n := w.count(`SELECT count(*) FROM app.kingdom_bosses WHERE kingdom_id = $1`, room); n != 1 {
		t.Fatalf("two runs of the cycle raised %d beasts", n)
	}
	row := standingBoss(w, room)

	// The wall is the kingdom's own Might, through the pure package's own
	// arithmetic: the service must not have a second copy of it.
	want := boss.HP(w.d.Config, kingdomMight(lords), 1)
	if row.HpMax != want || row.HpLeft != want {
		t.Fatalf("the beast was given %d/%d health, want %d", row.HpLeft, row.HpMax, want)
	}
	if int(row.Members) != len(lords) || row.KingdomMight != kingdomMight(lords) {
		t.Fatalf("the beast recorded %d members worth %d", row.Members, row.KingdomMight)
	}
	cycle := time.Duration(w.d.Config.Boss.CycleHours) * time.Hour
	if got := row.EndsAt.Sub(row.StartedAt); got != cycle {
		t.Fatalf("the window is %s, want %s", got, cycle)
	}

	// Killed and paid out inside the hour: still no second beast until the
	// window has run.
	w.exec(`UPDATE app.kingdom_bosses SET hp_left = 0, killed_at = $2, killed_by = $3 WHERE id = $1`,
		row.ID, w.now, lords[0].ID)
	w.runJob("boss_settle")
	if w.count(`SELECT count(*) FROM app.kingdom_bosses WHERE kingdom_id = $1 AND settled_at IS NOT NULL`,
		room) != 1 {
		t.Fatal("the cycle was not closed")
	}
	w.now = w.now.Add(time.Hour)
	w.runJob("boss_cycle")
	if n := w.count(`SELECT count(*) FROM app.kingdom_bosses WHERE kingdom_id = $1`, room); n != 1 {
		t.Fatalf("a beast rose an hour after the last one fell (%d rows)", n)
	}

	// And once the window has run, the next one comes round -- the next beast of
	// the six, one level harder.
	w.now = row.EndsAt.Add(time.Minute)
	w.runJob("boss_cycle")
	next := standingBoss(w, room)
	if next.ID == row.ID {
		t.Fatal("the window shut and no new beast rose")
	}
	if next.BossID == row.BossID {
		t.Fatalf("the same beast came round twice: %s", next.BossID)
	}
	if next.Level != 2 {
		t.Fatalf("the second beast is level %d, want 2 -- the first one fell", next.Level)
	}
	if next.HpMax <= row.HpMax {
		t.Fatalf("the second beast is no harder: %d against %d", next.HpMax, row.HpMax)
	}
}

// Six blows a lord, each one costing what a raid costs, and no seventh.
func TestSixBlowsAndNoMore(t *testing.T) {
	w := newWorld(t)
	room, lords := muster(w, 3, 30)
	w.runJob("boss_cycle")
	row := standingBoss(w, room)
	p := lords[0]

	cost := boss.EnergyCost(w.d.Config, int64(p.Level))
	var dealt int64
	var before sqlcdb.AppPlayer
	for i := 1; i <= w.d.Config.Boss.HitsPerMember; i++ {
		res, err := w.d.StrikeBoss(w.ctx, p.ID, w.reload(p.ID).ActionSeq+1)
		if err != nil {
			t.Fatalf("blow %d: %v", i, err)
		}
		if res.Replay == nil || res.Replay.Rounds > w.d.Config.Boss.RoundsPerHit {
			t.Fatalf("blow %d ran %d rounds", i, res.Replay.Rounds)
		}
		if res.HitsLeft != w.d.Config.Boss.HitsPerMember-i {
			t.Fatalf("after blow %d the lord has %d left", i, res.HitsLeft)
		}
		dealt += res.Damage
		if i == 1 {
			// The energy is measured from HERE: the test's lord is handed a
			// full pool by the harness, over the cap for their level, and the
			// first settle of the day is what brings it down to it.
			before = w.reload(p.ID)
		}
	}
	if _, err := w.d.StrikeBoss(w.ctx, p.ID, w.reload(p.ID).ActionSeq+1); !errors.Is(err, service.ErrNoBlows) {
		t.Fatalf("a seventh blow landed: %v", err)
	}

	after := w.reload(p.ID)
	spent := (before.EnergyMilli - after.EnergyMilli) / 1000
	if want := cost * int64(w.d.Config.Boss.HitsPerMember-1); spent != want {
		t.Fatalf("five blows cost %d energy, want %d (%d each)", spent, want, cost)
	}

	// What the lord did is written down once, as a total.
	hit, err := w.q.GetBossHit(w.ctx, sqlcdb.GetBossHitParams{CycleID: row.ID, PlayerID: p.ID})
	if err != nil {
		t.Fatal(err)
	}
	if int(hit.Hits) != w.d.Config.Boss.HitsPerMember || hit.Damage != dealt {
		t.Fatalf("the row says %d blows for %d damage; the answers said %d for %d",
			hit.Hits, hit.Damage, w.d.Config.Boss.HitsPerMember, dealt)
	}
	// And the wall came down by exactly what the lord was credited with.
	wounded, err := w.q.GetKingdomBoss(w.ctx, room)
	if err != nil {
		t.Fatal(err)
	}
	if wounded.HpMax-wounded.HpLeft != dealt {
		t.Fatalf("the beast lost %d and the lord was credited with %d",
			wounded.HpMax-wounded.HpLeft, dealt)
	}

	// The screen says the same thing the rows do.
	v, err := w.d.GetBoss(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !v.Standing || v.Beast == nil || v.Mine.HitsLeft != 0 || v.Mine.Damage != dealt {
		t.Fatalf("the card reads %+v", v.Mine)
	}
	if len(v.Damage) == 0 || v.Damage[0].PlayerID != p.ID.String() || !v.Damage[0].Mine {
		t.Fatal("the damage list does not have the only lord who struck at the top of it")
	}
	if v.Mine.CanStrike {
		t.Fatal("the card offers a seventh blow")
	}
}

// The chests go out when the cycle closes, once, with the first three's
// diamonds and the Slayer's title.
func TestTheBeastPaysWhenTheCycleCloses(t *testing.T) {
	w := newWorld(t)
	room, lords := muster(w, 3, 30)
	w.runJob("boss_cycle")
	row := standingBoss(w, room)

	// Two lords strike; the second one finds it on its knees and puts it down.
	if _, err := w.d.StrikeBoss(w.ctx, lords[1].ID, w.reload(lords[1].ID).ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	w.exec(`UPDATE app.kingdom_bosses SET hp_left = 1 WHERE id = $1`, row.ID)
	res, err := w.d.StrikeBoss(w.ctx, lords[0].ID, w.reload(lords[0].ID).ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Killed || res.HPLeft != 0 {
		t.Fatalf("the blow that emptied the bar did not kill it: %+v", res)
	}
	// A blow at a dead beast is refused rather than wasted.
	if _, err := w.d.StrikeBoss(w.ctx, lords[2].ID, w.reload(lords[2].ID).ActionSeq+1); !errors.Is(err, service.ErrBossDown) {
		t.Fatalf("the corpse took another blow: %v", err)
	}

	w.runJob("boss_settle")
	w.runJob("boss_settle") // twice: a settle pays nobody twice
	for _, p := range lords[:2] {
		if n := mailCount(w, p.ID, "boss"); n != 1 {
			t.Fatalf("a lord who struck has %d letters", n)
		}
	}
	if n := mailCount(w, lords[2].ID, "boss"); n != 0 {
		t.Fatalf("a lord who never struck was sent %d letters", n)
	}
	if w.count(`SELECT count(*) FROM app.boss_hits WHERE cycle_id = $1 AND paid_at IS NULL`, row.ID) != 0 {
		t.Fatal("somebody who struck was not paid")
	}
	if w.count(`SELECT count(*) FROM app.kingdom_bosses WHERE id = $1 AND settled_at IS NOT NULL`,
		row.ID) != 1 {
		t.Fatal("the cycle was not closed")
	}

	// The first on the damage list takes the diamonds and wears the title.
	top, err := w.q.ListBossDamage(w.ctx, sqlcdb.ListBossDamageParams{CycleID: row.ID, Lim: 3})
	if err != nil {
		t.Fatal(err)
	}
	best := top[0].PlayerID
	letters := w.letters(w.reload(best), "boss:")
	if len(letters) != 1 {
		t.Fatalf("the best lord has %d letters", len(letters))
	}
	if got := letters[0].Grant.Diamonds; got < w.d.Config.Boss.TopDiamonds[0] {
		t.Fatalf("the best lord's letter carries %d diamonds, want at least the place's %d",
			got, w.d.Config.Boss.TopDiamonds[0])
	}
	if n := w.count(`SELECT count(*) FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = $2`,
		best, w.d.Config.Boss.TopTitle); n != 1 {
		t.Fatalf("the Slayer holds the title %d times", n)
	}
}

// --- the wars ---------------------------------------------------------------

// warSaturday is noon on a Saturday: inside the fighting, with the draw behind
// it and the settling ahead. The tests stand here rather than on the day they
// happen to be run -- and each of them a week further on, because a week is
// drawn ONCE (admin.period_closes) and two tests sharing one would find the
// second draw already done.
var warSaturday = time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

var warWeeksUsed int

func nextWarSaturday() time.Time {
	warWeeksUsed++
	return warSaturday.AddDate(0, 0, 7*warWeeksUsed)
}

// twoKingdomsAtWar musters two halls strong enough to be the top of the draw
// (so a hall left behind by another test cannot be drawn into the middle of
// it), runs the draw, and hands back the war.
func twoKingdomsAtWar(w *world) (sqlcdb.AppWar, uuid.UUID, []sqlcdb.AppPlayer, uuid.UUID, []sqlcdb.AppPlayer) {
	w.t.Helper()
	w.now = nextWarSaturday()
	roomA, ours := muster(w, 3, 40)
	roomB, theirs := muster(w, 3, 40)
	// Equal to each other, and stronger than every hall an earlier test left in
	// the database: the draw sorts by Might and pairs neighbours, so this is
	// what puts these two at the top of the list and against each other.
	might := int64(5_000_000) * int64(warWeeksUsed+1)
	for _, p := range append(append([]sqlcdb.AppPlayer{}, ours...), theirs...) {
		w.exec(`UPDATE app.players SET might = $2 WHERE id = $1`, p.ID, might)
	}
	w.runJob("war_draw")
	w.runJob("war_draw") // twice: a week is drawn once

	row, err := w.q.GetWarFor(w.ctx, sqlcdb.GetWarForParams{
		Week: w.d.WarWeekOf(w.now), KingdomID: roomA,
	})
	if err != nil {
		w.t.Fatalf("no war was drawn: %v", err)
	}
	// Either kingdom may be the A side: the draw sorts by Might and the pair is
	// what matters, not which half of it a hall landed in.
	pair := map[uuid.UUID]bool{row.AID: true}
	if row.BID != nil {
		pair[*row.BID] = true
	}
	if !pair[roomA] || !pair[roomB] {
		w.t.Fatalf("the two strongest kingdoms were not drawn against each other: %+v", row)
	}
	return row, roomA, ours, roomB, theirs
}

// The pairs are drawn once a week, on the evening the balance names, and the
// fighting runs the days after it.
func TestAWarIsDrawnOnceAWeek(t *testing.T) {
	w := newWorld(t)
	row, roomA, _, roomB, _ := twoKingdomsAtWar(w)

	if n := w.count(`SELECT count(*) FROM app.wars WHERE a_id = $1 OR b_id = $1`, roomA); n != 1 {
		t.Fatalf("the kingdom is in %d wars this week", n)
	}
	want := w.now.Truncate(24 * time.Hour)
	if !row.StartsAt.Equal(want) {
		t.Fatalf("the war starts %s, want the midnight after the draw (%s)", row.StartsAt, want)
	}
	if row.StartsAt.Weekday() != time.Saturday {
		t.Fatalf("the fighting begins on a %s", row.StartsAt.Weekday())
	}
	if got := row.EndsAt.Sub(row.StartsAt); got != time.Duration(w.d.Config.War.Days)*24*time.Hour {
		t.Fatalf("the war runs %s", got)
	}
	// Both halls were told.
	for _, room := range []uuid.UUID{roomA, roomB} {
		if w.count(`SELECT count(*) FROM app.chat_messages WHERE kingdom_id = $1 AND system_kind = 'war'`,
			room) != 1 {
			t.Fatal("a hall was not told about the war")
		}
	}
}

// A war attack moves points and nothing else: no gold, no energy, no shield, no
// sequence.
func TestAWarAttackMovesPointsAndNothingElse(t *testing.T) {
	w := newWorld(t)
	row, _, ours, _, theirs := twoKingdomsAtWar(w)
	me, foe := ours[0], theirs[0]
	w.exec(`UPDATE app.players SET gold = 100000 WHERE id = $1 OR id = $2`, me.ID, foe.ID)
	// The pool is settled first. A lord the harness handed a full 300 is over
	// the cap for their level, and the first snapshot of the day is what brings
	// them down to it -- which would read as a war attack spending energy.
	for _, id := range []uuid.UUID{me.ID, foe.ID} {
		if _, err := w.d.GetState(w.ctx, id); err != nil {
			t.Fatal(err)
		}
	}
	before, defBefore := w.reload(me.ID), w.reload(foe.ID)

	res, err := w.d.WarAttack(w.ctx, me.ID, foe.ID)
	if err != nil {
		t.Fatalf("attacking: %v", err)
	}
	after, defAfter := w.reload(me.ID), w.reload(foe.ID)
	if after.Gold != before.Gold || defAfter.Gold != defBefore.Gold {
		t.Fatalf("gold moved: %d -> %d and %d -> %d",
			before.Gold, after.Gold, defBefore.Gold, defAfter.Gold)
	}
	if after.EnergyMilli != before.EnergyMilli {
		t.Fatalf("energy moved: %d -> %d", before.EnergyMilli, after.EnergyMilli)
	}
	if after.ActionSeq != before.ActionSeq {
		t.Fatalf("the sequence moved: %d -> %d", before.ActionSeq, after.ActionSeq)
	}
	if defAfter.ShieldUntil != defBefore.ShieldUntil {
		t.Fatal("a war attack applied or broke a shield")
	}
	if after.KingdomRepToday != before.KingdomRepToday {
		t.Fatal("a war attack fed the Throne")
	}

	// The points landed on the attacker's side, and the defender's side took
	// what holding is worth when it held.
	fresh, err := w.q.GetWar(w.ctx, row.ID)
	if err != nil {
		t.Fatal(err)
	}
	mine, held := int64(fresh.APoints), int64(fresh.BPoints)
	if fresh.AID != *w.reload(me.ID).KingdomID {
		mine, held = held, mine
	}
	if res.Won && mine != res.Points {
		t.Fatalf("a win of %d points left the side on %d", res.Points, mine)
	}
	if !res.Won && (mine != res.Points || held != res.HeldPoints) {
		t.Fatalf("a loss put %d/%d on the board, want %d/%d",
			mine, held, res.Points, res.HeldPoints)
	}
	if res.Replay == nil || res.BattleID == "" {
		t.Fatal("there is no battle to watch")
	}
	if w.count(`SELECT count(*) FROM app.battles WHERE id = $1 AND kind = 'war' AND gold_stolen = 0`,
		res.BattleID) != 1 {
		t.Fatal("the battle was not stored as a war that stole nothing")
	}

	// Three a day, and no fourth.
	for i := 2; i <= w.d.Config.War.AttacksPerDay; i++ {
		if _, err := w.d.WarAttack(w.ctx, me.ID, theirs[i-1].ID); err != nil {
			t.Fatalf("attack %d: %v", i, err)
		}
	}
	if _, err := w.d.WarAttack(w.ctx, me.ID, foe.ID); !errors.Is(err, service.ErrNoWarAttack) {
		t.Fatalf("a fourth attack landed: %v", err)
	}
	// And the day turning gives them back.
	w.now = w.now.Add(24 * time.Hour)
	if _, err := w.d.WarAttack(w.ctx, me.ID, foe.ID); err != nil {
		t.Fatalf("the next day: %v", err)
	}

	// Nobody may be thrown at their own side, or at a lord outside the war.
	if _, err := w.d.WarAttack(w.ctx, me.ID, ours[1].ID); !errors.Is(err, service.ErrWarNotFoe) {
		t.Fatalf("a lord attacked his own kingdom: %v", err)
	}
	stranger := w.player(40, 0)
	if _, err := w.d.WarAttack(w.ctx, me.ID, stranger.ID); !errors.Is(err, service.ErrWarNotFoe) {
		t.Fatalf("a lord outside the war was attacked: %v", err)
	}
}

// Three banners and the lord is routed: they may still be beaten, and beating
// them is worth a quarter.
func TestARoutedLordIsWorthAQuarter(t *testing.T) {
	w := newWorld(t)
	row, _, ours, _, theirs := twoKingdomsAtWar(w)
	me, foe := ours[0], theirs[0]

	full, err := w.d.GetWar(w.ctx, me.ID)
	if err != nil {
		t.Fatal(err)
	}
	var whole int64
	for _, e := range full.Enemies {
		if e.PlayerID == foe.ID.String() {
			whole = e.Worth
			if e.Routed || e.BannersLost != 0 {
				t.Fatal("a lord who has lost nothing is already routed")
			}
		}
	}
	if whole <= 0 {
		t.Fatal("the card does not say what a lord is worth")
	}

	// Their banners, taken by somebody else so the asker's own three are
	// untouched.
	for i := 0; i < w.d.Config.War.Banners; i++ {
		w.exec(`INSERT INTO app.war_attacks (war_id, attacker_id, defender_id, side, won, points, created_at)
		        VALUES ($1, $2, $3, 'a', true, 10, $4)`, row.ID, ours[1].ID, foe.ID, w.now)
	}
	after, err := w.d.GetWar(w.ctx, me.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range after.Enemies {
		if e.PlayerID != foe.ID.String() {
			continue
		}
		if !e.Routed || e.BannersLost != w.d.Config.War.Banners {
			t.Fatalf("a lord who lost every banner reads %+v", e)
		}
		want := whole * w.d.Config.War.RoutBP / 10000
		if e.Worth != want {
			t.Fatalf("a routed lord is worth %d, want %d (a quarter of %d)", e.Worth, want, whole)
		}
	}
	// And the attack itself pays that quarter.
	res, err := w.d.WarAttack(w.ctx, me.ID, foe.ID)
	if err != nil {
		t.Fatal(err)
	}
	if res.Won && res.Points != whole*w.d.Config.War.RoutBP/10000 {
		t.Fatalf("beating a routed lord paid %d", res.Points)
	}
	if !res.Routed {
		t.Fatal("the attack was not told the lord was routed")
	}
}

// The week is paid out once: the purse to every lord who rode out, renown and
// experience to the kingdoms, and the title to the best lord in the war.
func TestTheWarPaysBothSidesAndNamesTheWarlord(t *testing.T) {
	w := newWorld(t)
	row, roomA, ours, roomB, theirs := twoKingdomsAtWar(w)

	if _, err := w.d.WarAttack(w.ctx, ours[0].ID, theirs[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.WarAttack(w.ctx, theirs[0].ID, ours[0].ID); err != nil {
		t.Fatal(err)
	}
	// A's second lord rides out twice, so one side is ahead and one lord is
	// clearly the best in the war.
	for i := 0; i < 2; i++ {
		if _, err := w.d.WarAttack(w.ctx, ours[1].ID, theirs[i].ID); err != nil {
			t.Fatal(err)
		}
	}
	// A hand on the scale so the week has a winner whatever the fights did --
	// on whichever half of the pair our own kingdom landed in.
	ahead, behind := int32(100), int32(10)
	if row.AID != roomA {
		ahead, behind = behind, ahead
	}
	w.exec(`UPDATE app.wars SET a_points = $2, b_points = $3 WHERE id = $1`, row.ID, ahead, behind)
	w.exec(`UPDATE app.war_attacks SET points = 60 WHERE war_id = $1 AND attacker_id = $2`,
		row.ID, ours[1].ID)

	before := w.count(`SELECT reputation FROM app.kingdoms WHERE id = $1`, roomA)
	w.now = row.EndsAt.Add(time.Minute)
	w.runJob("war_settle")
	w.runJob("war_settle") // twice: a week is paid once

	fresh, err := w.q.GetWar(w.ctx, row.ID)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.SettledAt == nil || fresh.WinnerID == nil || *fresh.WinnerID != roomA {
		t.Fatalf("the war closed as %+v", fresh)
	}
	for _, p := range []uuid.UUID{ours[0].ID, ours[1].ID, theirs[0].ID} {
		if n := mailCount(w, p, "war"); n != 1 {
			t.Fatalf("a lord who rode out has %d letters", n)
		}
	}
	if n := mailCount(w, ours[2].ID, "war"); n != 0 {
		t.Fatalf("a lord who watched the week go by has %d letters", n)
	}

	// The winner's purse is the bigger one.
	winner := w.letters(w.reload(ours[1].ID), "war:")
	loser := w.letters(w.reload(theirs[0].ID), "war:")
	if len(winner) != 1 || len(loser) != 1 {
		t.Fatalf("%d and %d letters", len(winner), len(loser))
	}
	if winner[0].Grant.GoldWages <= loser[0].Grant.GoldWages {
		t.Fatal("losing pays as well as winning")
	}

	// A kingdom that never got on the board is paid NOTHING -- not the purse,
	// and above all not the renown, which feeds the Throne. Proved on a war of
	// its own, because this one's two sides both fought.
	idle := w.idleWar()
	if w.count(`SELECT reputation FROM app.kingdoms WHERE id = $1`, idle) != 0 {
		t.Fatal("a kingdom that ignored its war for three days took renown for it")
	}

	// The kingdoms took renown and experience, the winner more of both.
	repA := w.count(`SELECT reputation FROM app.kingdoms WHERE id = $1`, roomA)
	repB := w.count(`SELECT reputation FROM app.kingdoms WHERE id = $1`, roomB)
	if repA <= before || repA <= repB {
		t.Fatalf("renown: the winner has %d (was %d), the loser %d", repA, before, repB)
	}
	xpA := w.count(`SELECT xp FROM app.kingdoms WHERE id = $1`, roomA)
	if int64(xpA) != w.d.Config.War.Won.KingdomXP {
		t.Fatalf("the winning kingdom took %d experience, want %d", xpA, w.d.Config.War.Won.KingdomXP)
	}
	// And the renown reached the week the Throne is decided on.
	if w.count(`SELECT count(*) FROM app.kingdom_week WHERE kingdom_id = $1`, roomA) != 1 {
		t.Fatal("the war's renown never reached the week's count")
	}

	// The Warlord is the lord who did most, on either side -- one of them, and
	// the right one. Counted among THIS war's lords: the database has the
	// Warlords of every week the tests before this one fought.
	inWar := []uuid.UUID{}
	for _, p := range append(append([]sqlcdb.AppPlayer{}, ours...), theirs...) {
		inWar = append(inWar, p.ID)
	}
	if n := w.count(`SELECT count(*) FROM app.player_cosmetics
	                 WHERE cosmetic_id = $1 AND player_id = ANY($2)`,
		w.d.Config.War.WarlordTitle, inWar); n != 1 {
		t.Fatalf("%d lords of this war are Warlord of the Week", n)
	}
	if w.count(`SELECT count(*) FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = $2`,
		ours[1].ID, w.d.Config.War.WarlordTitle) != 1 {
		t.Fatal("the Warlord is not the lord who took the most points")
	}
}

// idleWar draws a war nobody turns up to, settles it, and hands back one of the
// two kingdoms.
func (w *world) idleWar() uuid.UUID {
	w.t.Helper()
	row, roomA, _, _, _ := twoKingdomsAtWar(w)
	w.now = row.EndsAt.Add(time.Minute)
	w.runJob("war_settle")
	fresh, err := w.q.GetWar(w.ctx, row.ID)
	if err != nil {
		w.t.Fatal(err)
	}
	if fresh.SettledAt == nil || fresh.WinnerID != nil {
		w.t.Fatalf("a war nobody fought closed as %+v", fresh)
	}
	return roomA
}
