//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// PvE ve derinlik (Wave 7), end to end: the campaign, the expeditions, the
// forge and the talent tree, against a real database.

// soldier puts one soldier of a rank in a lord's yard.
func soldier(w *world, p sqlcdb.AppPlayer, slot int, tier string) uuid.UUID {
	w.t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(w.ctx,
		`INSERT INTO app.soldiers (player_id, slot_index, type_id, tier, level, name, rolled_config_version)
		 VALUES ($1, $2, 'peasant', $3, $4, 'A Soldier', 1) RETURNING id`,
		p.ID, slot, tier, p.Level).Scan(&id); err != nil {
		w.t.Fatal(err)
	}
	w.exec(`UPDATE app.players SET soldier_slots = GREATEST(soldier_slots, $2) WHERE id = $1`, p.ID, slot)
	return id
}

// giveItem puts one piece of gear in a lord's bag and hands back its id.
func giveItem(w *world, p sqlcdb.AppPlayer, slot, tier string, ilvl int32) uuid.UUID {
	w.t.Helper()
	atk, def, spd := items.Stat(w.d.Config, slot, tier, int64(ilvl), 100, false)
	var id uuid.UUID
	if err := pool.QueryRow(w.ctx,
		`INSERT INTO app.player_items (player_id, def_id, slot, tier, ilvl, quality_pct, masterwork,
		     attack, defense, speed, acquired_from, rolled_config_version)
		 VALUES ($1, $2, $3, $4, $5, 100, false, $6, $7, $8, 'admin', 1) RETURNING id`,
		p.ID, defFor(w, slot, tier), slot, tier, ilvl, atk, def, spd).Scan(&id); err != nil {
		w.t.Fatal(err)
	}
	return id
}

// defFor is any definition of that slot and rank: the forge does not care which
// sword went in, only what it was worth.
func defFor(w *world, slot, tier string) string {
	defs := w.d.Config.ItemDefsFor(slot, tier)
	if len(defs) == 0 {
		w.t.Fatalf("no %s %s in the catalogue", tier, slot)
	}
	return defs[0].ID
}

// wageAt is what the lord's best job pays: the snapshot's own number, which is
// already through every bucket. A talent in the economy branch has to move it,
// because that is the only thing "it lands in the same bucket an upgrade does"
// can mean from outside.
func wageAt(w *world, id uuid.UUID) int64 {
	w.t.Helper()
	snap, err := w.d.GetState(w.ctx, id)
	if err != nil {
		w.t.Fatal(err)
	}
	var best int64
	for _, j := range snap.Jobs {
		if j.Unlocked && j.GoldPayout > best {
			best = j.GoldPayout
		}
	}
	return best
}

// strong makes a lord who can actually win the first mile: the stage ladder was
// cut for a lord with gear and a roster, so a naked level-6 lord loses.
func strong(w *world, level int32, gold int64) sqlcdb.AppPlayer {
	w.t.Helper()
	p := w.player(level, gold)
	w.exec(`UPDATE app.players SET stat_attack = $2, stat_defense = $2 WHERE id = $1`, p.ID, 200)
	for i := 1; i <= 5; i++ {
		soldier(w, p, i, "epic")
	}
	return w.reload(p.ID)
}

// --- the campaign ---

func TestTheRoadOpensOneMileAtATime(t *testing.T) {
	w := newWorld(t)
	p := strong(w, 10, 10_000)

	v, err := w.d.GetCampaign(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !v.Unlocked || len(v.Chapters) == 0 {
		t.Fatalf("the campaign is shut to a level-10 lord: %+v", v.Unlocked)
	}
	first := v.Chapters[0]
	if v.ChapterID != first.ID || v.Stage != 1 {
		t.Fatalf("a new lord stands at %s %d", v.ChapterID, v.Stage)
	}

	// The second mile is shut until the first has fallen.
	if _, err := w.d.FightStage(w.ctx, p.ID, first.ID, 2, p.ActionSeq+1); !errors.Is(err, service.ErrStageShut) {
		t.Fatalf("the second mile was walked first: %v", err)
	}

	// Fortune of War is rolled per battle, so even a lord the mile was written
	// for loses one now and then. The road is what is being tested, not the
	// dice: it is walked until it falls, and five is well past any run the
	// simulator can produce at this ratio.
	var res *service.StageResult
	seq := p.ActionSeq
	for i := 0; i < 5 && (res == nil || !res.Won); i++ {
		seq++
		var err error
		res, err = w.d.FightStage(w.ctx, p.ID, first.ID, 1, seq)
		if err != nil {
			t.Fatal(err)
		}
	}
	if !res.Won {
		t.Fatalf("five walks and the campaign's first mile still stood (hp left %d bp)",
			res.Replay.AttackerHPLeftBP)
	}
	if res.Stars < 1 || res.Stars > 3 {
		t.Fatalf("a win was worth %d stars", res.Stars)
	}
	if !res.FirstClear || res.Granted.Gold <= 0 {
		t.Fatalf("the first clear paid %d gold", res.Granted.Gold)
	}
	// The energy was spent, the sequence moved, and the second mile is open.
	after := w.reload(p.ID)
	if after.ActionSeq != seq {
		t.Fatalf("the fight left the sequence at %d, not %d", after.ActionSeq, seq)
	}
	ch, err := w.d.GetChapter(w.ctx, p.ID, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !ch.Stages[1].Open {
		t.Fatal("the second mile stayed shut after the first fell")
	}
	if ch.Stages[0].Stars != res.Stars {
		t.Fatalf("the map says %d stars and the fight paid %d", ch.Stages[0].Stars, res.Stars)
	}
}

// A repeat pays a share, never the first clear's three times -- and never more
// than the same energy would have collected.
func TestARepeatPaysLessThanTheFirstClear(t *testing.T) {
	w := newWorld(t)
	p := strong(w, 12, 10_000)
	first := w.d.Config.ChapterAt(0)

	var won *service.StageResult
	seq := p.ActionSeq
	for i := 0; i < 6 && (won == nil || !won.Won); i++ {
		seq++
		res, err := w.d.FightStage(w.ctx, p.ID, first.ID, 1, seq)
		if err != nil {
			t.Fatal(err)
		}
		won = res
	}
	if !won.Won {
		t.Skip("six attempts and the first mile never fell")
	}
	firstGold := won.Granted.Gold

	seq++
	again, err := w.d.FightStage(w.ctx, p.ID, first.ID, 1, seq)
	if err != nil {
		t.Fatal(err)
	}
	if !again.Won {
		t.Skip("the repeat was lost")
	}
	if again.FirstClear {
		t.Fatal("the second clear called itself the first")
	}
	if again.Granted.Gold >= firstGold {
		t.Fatalf("a repeat paid %d and the first clear paid %d", again.Granted.Gold, firstGold)
	}
}

func TestAChapterChestOpensOnStarsAndIsTakenOnce(t *testing.T) {
	w := newWorld(t)
	p := strong(w, 20, 10_000)
	ch := w.d.Config.ChapterAt(0)

	// Nothing earned: the chest is shut.
	if _, err := w.d.ClaimChapterChest(w.ctx, p.ID, ch.ID, 0, p.ActionSeq+1); !errors.Is(err, service.ErrChestShut) {
		t.Fatalf("an empty chapter opened its chest: %v", err)
	}
	// Hand the lord the stars the first chest asks for.
	for _, st := range ch.Stages {
		w.exec(`INSERT INTO app.player_campaign (player_id, chapter_id, stage, stars)
		        VALUES ($1,$2,$3,3)`, p.ID, ch.ID, st.Stage)
	}
	seq := p.ActionSeq + 1
	got, err := w.d.ClaimChapterChest(w.ctx, p.ID, ch.ID, 0, seq)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Granted.Lines) == 0 {
		t.Fatal("the chest paid nothing at all")
	}
	if _, err := w.d.ClaimChapterChest(w.ctx, p.ID, ch.ID, 0, seq+1); !errors.Is(err, service.ErrChestTaken) {
		t.Fatalf("the same chest was taken twice: %v", err)
	}
}

// --- the expeditions ---

func TestASoldierSentOutIsAwayFromEverything(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 10_000)
	sid := soldier(w, p, 1, "rare")
	field := w.d.Config.Hunt.Fields[0]

	before, err := w.d.GetArmy(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if before.Field.Might != before.Totals.Might {
		t.Fatal("a lord with nobody away has a thinner field than roster")
	}

	v, err := w.d.SendHunt(w.ctx, p.ID, sid, field.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(v.Away) != 1 || v.Away[0].Back {
		t.Fatalf("after sending one soldier: %+v", v.Away)
	}

	// Away: not in the field, still on the roster the tables read.
	army, err := w.d.GetArmy(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if army.Totals.Might != before.Totals.Might {
		t.Fatalf("the roster's Might moved from %d to %d when a soldier left",
			before.Totals.Might, army.Totals.Might)
	}
	if army.Field.Might >= army.Totals.Might {
		t.Fatalf("the field is %d and the roster %d: the soldier is still marching",
			army.Field.Might, army.Totals.Might)
	}
	if army.Slots[0].Soldier.Away == nil {
		t.Fatal("the card wears no ribbon")
	}

	// And away from every other verb.
	if _, err := w.d.RerollSoldier(w.ctx, p.ID, sid, p.ActionSeq+1); !errors.Is(err, service.ErrHuntAway) {
		t.Fatalf("a soldier on the road was rerolled: %v", err)
	}
	if _, err := w.d.Dismiss(w.ctx, p.ID, sid, p.ActionSeq+1); !errors.Is(err, service.ErrHuntAway) {
		t.Fatalf("a soldier on the road was let go: %v", err)
	}
	// Twice out is once too many.
	if _, err := w.d.SendHunt(w.ctx, p.ID, sid, field.ID); !errors.Is(err, service.ErrHuntAway) {
		t.Fatalf("one soldier walked two roads: %v", err)
	}
}

func TestAnExpeditionPaysWhatWasRolledAtTheTap(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 10_000)
	sid := soldier(w, p, 1, "rare")
	field := w.d.Config.Hunt.Fields[0]

	v, err := w.d.SendHunt(w.ctx, p.ID, sid, field.ID)
	if err != nil {
		t.Fatal(err)
	}
	away := v.Away[0]

	// Too soon.
	id := uuid.MustParse(away.ID)
	if _, err := w.d.CollectHunt(w.ctx, p.ID, id, p.ActionSeq+1); !errors.Is(err, service.ErrHuntSoon) {
		t.Fatalf("a soldier was let in early: %v", err)
	}

	w.now = w.now.Add(time.Duration(field.Hours)*time.Hour + time.Minute)
	got, err := w.d.CollectHunt(w.ctx, p.ID, id, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Granted.Gold <= 0 {
		t.Fatalf("the road paid %d gold", got.Granted.Gold)
	}
	if len(got.Hunt.Away) != 0 {
		t.Fatalf("the soldier is still away: %+v", got.Hunt.Away)
	}
	// Twice is once too many.
	if _, err := w.d.CollectHunt(w.ctx, p.ID, id, p.ActionSeq+2); !errors.Is(err, service.ErrHuntGone) {
		t.Fatalf("one expedition paid twice: %v", err)
	}
	// And the soldier is home for every other verb.
	if _, err := w.d.SendHunt(w.ctx, p.ID, sid, field.ID); err != nil {
		t.Fatalf("a soldier home from the road could not be sent again: %v", err)
	}
}

func TestARecallBringsNothing(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 10_000)
	sid := soldier(w, p, 1, "rare")

	v, err := w.d.SendHunt(w.ctx, p.ID, sid, w.d.Config.Hunt.Fields[1].ID)
	if err != nil {
		t.Fatal(err)
	}
	before := w.reload(p.ID)
	if _, err := w.d.RecallHunt(w.ctx, p.ID, uuid.MustParse(v.Away[0].ID)); err != nil {
		t.Fatal(err)
	}
	after := w.reload(p.ID)
	if after.Gold != before.Gold || after.Xp != before.Xp {
		t.Fatalf("a recall paid %d gold and %d experience",
			after.Gold-before.Gold, after.Xp-before.Xp)
	}
	// The soldier is home.
	if _, err := w.d.SendHunt(w.ctx, p.ID, sid, w.d.Config.Hunt.Fields[0].ID); err != nil {
		t.Fatalf("a recalled soldier is still away: %v", err)
	}
}

func TestTheHuntHasOnlyAsManySlotsAsTheLevelGives(t *testing.T) {
	w := newWorld(t)
	p := w.player(int32(w.d.Config.Hunt.Slots[0].Level), 10_000)
	a := soldier(w, p, 1, "common")
	b := soldier(w, p, 2, "common")
	f := w.d.Config.Hunt.Fields[0].ID

	if _, err := w.d.SendHunt(w.ctx, p.ID, a, f); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.SendHunt(w.ctx, p.ID, b, f); !errors.Is(err, service.ErrHuntSlots) {
		t.Fatalf("a lord with one slot sent two soldiers: %v", err)
	}
}

// --- the forge ---

func TestTheForgeEatsThreeAndMakesOne(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 1_000_000)
	ids := make([]uuid.UUID, 0, 3)
	for i := 0; i < 3; i++ {
		ids = append(ids, giveItem(w, p, "weapon", "common", 10))
	}
	before := w.reload(p.ID)

	got, err := w.d.Forge(w.ctx, p.ID, ids, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Item.Tier != items.NextTier(w.d.Config, "common") {
		t.Fatalf("three commons made a %s", got.Item.Tier)
	}
	if got.Fee <= 0 {
		t.Fatal("the anvil asked for nothing")
	}
	after := w.reload(p.ID)
	if before.Gold-after.Gold != got.Fee {
		t.Fatalf("the fee was %d and the purse lost %d", got.Fee, before.Gold-after.Gold)
	}
	// The three are gone and the one is there.
	var n int64
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.player_items WHERE player_id = $1`,
		p.ID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("the bag holds %d pieces after forging three into one", n)
	}
	var from string
	if err := pool.QueryRow(w.ctx,
		`SELECT acquired_from FROM app.player_items WHERE player_id = $1`, p.ID).Scan(&from); err != nil {
		t.Fatal(err)
	}
	if from != "forge" {
		t.Fatalf("the forged piece says it came from %q", from)
	}
}

func TestTheForgeRefusesAMixedPile(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 1_000_000)
	ids := []uuid.UUID{
		giveItem(w, p, "weapon", "common", 10),
		giveItem(w, p, "weapon", "common", 10),
		giveItem(w, p, "armor", "common", 10),
	}
	if _, err := w.d.Forge(w.ctx, p.ID, ids, p.ActionSeq+1); !errors.Is(err, service.ErrForgePieces) {
		t.Fatalf("a sword, a sword and a breastplate were forged: %v", err)
	}
	// Two pieces are not three.
	if _, err := w.d.Forge(w.ctx, p.ID, ids[:2], p.ActionSeq+1); !errors.Is(err, service.ErrForgePieces) {
		t.Fatalf("two pieces were forged: %v", err)
	}
}

// --- the talent tree ---

func TestATalentLandsInTheSameBucketAnUpgradeDoes(t *testing.T) {
	w := newWorld(t)
	p := w.player(60, 1_000_000)

	v, err := w.d.GetTalents(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !v.Unlocked || v.Left <= 0 {
		t.Fatalf("a level-60 lord has %d points left", v.Left)
	}
	// The economy branch's first talent lifts what a job pays.
	eco := w.d.Config.Talents.Branch("economy")
	if eco == nil {
		t.Skip("no economy branch")
	}
	first := eco.Talents[0]

	before := wageAt(w, p.ID)
	seq := p.ActionSeq
	for i := 0; i < first.Ranks; i++ {
		seq++
		if _, err := w.d.BuyTalent(w.ctx, p.ID, first.ID, seq); err != nil {
			t.Fatal(err)
		}
	}
	after := wageAt(w, p.ID)
	if after <= before {
		t.Fatalf("four ranks of %s changed a job's pay from %d to %d", first.ID, before, after)
	}

	// A rank past the last is refused, and so is a tier whose gate is unpaid.
	// A refusal writes nothing, so the same sequence number is still the next
	// one -- which is itself worth holding: a refused tap must not strand the
	// client's queue.
	seq++
	if _, err := w.d.BuyTalent(w.ctx, p.ID, first.ID, seq); !errors.Is(err, service.ErrTalentMaxed) {
		t.Fatalf("a maxed talent took another rank: %v", err)
	}
	deep := eco.Talents[len(eco.Talents)-1]
	if _, err := w.d.BuyTalent(w.ctx, p.ID, deep.ID, seq); !errors.Is(err, service.ErrTalentShut) {
		t.Fatalf("a shut tier was bought: %v", err)
	}
	if now := w.reload(p.ID); now.ActionSeq != seq-1 {
		t.Fatalf("two refused taps moved the sequence to %d", now.ActionSeq)
	}
}

func TestARespecCostsGoldAndGivesEveryPointBack(t *testing.T) {
	w := newWorld(t)
	p := w.player(60, 10_000_000)
	first := w.d.Config.Talents.Branches[0].Talents[0]

	seq := p.ActionSeq + 1
	if _, err := w.d.BuyTalent(w.ctx, p.ID, first.ID, seq); err != nil {
		t.Fatal(err)
	}
	before := w.reload(p.ID)
	seq++
	got, err := w.d.RespecTalents(w.ctx, p.ID, seq)
	if err != nil {
		t.Fatal(err)
	}
	after := w.reload(p.ID)
	if before.Gold-after.Gold != w.d.Config.Talents.Respec.BaseGold {
		t.Fatalf("the first respec cost %d", before.Gold-after.Gold)
	}
	if got.Talents.Spent != 0 || got.Talents.Left != got.Talents.Points {
		t.Fatalf("after a respec: %d spent, %d of %d left",
			got.Talents.Spent, got.Talents.Left, got.Talents.Points)
	}
	if got.Talents.RespecCost <= w.d.Config.Talents.Respec.BaseGold {
		t.Fatalf("the second respec costs %d, not more than the first", got.Talents.RespecCost)
	}
	// Nothing left to take back.
	seq++
	if _, err := w.d.RespecTalents(w.ctx, p.ID, seq); !errors.Is(err, service.ErrNoTalents) {
		t.Fatalf("an empty tree was respecced: %v", err)
	}
}
