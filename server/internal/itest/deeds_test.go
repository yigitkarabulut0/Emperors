//go:build integration

package itest

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
)

// deedsOf reads every counter a player has, as scope/period -> deed -> value.
func deedsOf(w *world, id uuid.UUID) map[string]map[int64]map[string]int64 {
	w.t.Helper()
	rows, err := pool.Query(w.ctx, `SELECT scope, period, deed, value FROM app.player_deeds
		WHERE player_id = $1`, id)
	if err != nil {
		w.t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]map[int64]map[string]int64{}
	for rows.Next() {
		var scope, deed string
		var period, value int64
		if err := rows.Scan(&scope, &period, &deed, &value); err != nil {
			w.t.Fatal(err)
		}
		if out[scope] == nil {
			out[scope] = map[int64]map[string]int64{}
		}
		if out[scope][period] == nil {
			out[scope][period] = map[string]int64{}
		}
		out[scope][period][deed] = value
	}
	if err := rows.Err(); err != nil {
		w.t.Fatal(err)
	}
	return out
}

// Collects are counted for a lifetime, for the player's own week and for the
// UTC week, and the two weeks are told apart where the player's midnight is
// not UTC's.
func TestDeedsLandInEveryScope(t *testing.T) {
	w := newWorld(t)
	// Sunday 23:30 in UTC; the player lives an hour ahead, where it is already
	// Monday and a new week.
	w.now = time.Date(2026, 9, 20, 23, 30, 0, 0, time.UTC)
	p := w.player(1, 0)
	w.exec(`UPDATE app.players SET reset_offset_minutes = 60 WHERE id = $1`, p.ID)
	p = w.reload(p.ID)

	if _, err := w.d.Collect(w.ctx, p.ID, "grapes", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.CollectBatch(w.ctx, p.ID, []string{"grapes", "grapes"}, p.ActionSeq+2); err != nil {
		t.Fatal(err)
	}
	p = w.reload(p.ID)
	cost := w.d.Config.Job("grapes").EnergyCost

	localWeek := deeds.EpochDay(time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC))
	utcWeek := deeds.EpochDay(time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC))
	got := deedsOf(w, p.ID)
	for _, at := range []struct {
		scope  string
		period int64
	}{{deeds.ScopeLife, 0}, {deeds.ScopeWeek, localWeek}, {deeds.ScopeUWeek, utcWeek}} {
		row := got[at.scope][at.period]
		if row["collects"] != 3 || row["energy"] != 3*cost || row["xp"] != p.Xp {
			t.Errorf("%s/%d holds %v; want 3 collects, %d energy, %d xp", at.scope, at.period, row, 3*cost, p.Xp)
		}
	}
	if len(got[deeds.ScopeWeek]) != 1 || len(got[deeds.ScopeUWeek]) != 1 {
		t.Fatalf("the weeks landed in %d local and %d UTC periods, want one each: %v",
			len(got[deeds.ScopeWeek]), len(got[deeds.ScopeUWeek]), got)
	}

	// Today's tasks still count, on the player's own day.
	var collects, energy int32
	day := pgtype.Date{Time: time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC), Valid: true}
	if err := pool.QueryRow(w.ctx, `SELECT collects, energy FROM app.player_quests
		WHERE player_id = $1 AND day = $2`, p.ID, day).Scan(&collects, &energy); err != nil {
		t.Fatalf("no quest row on the player's Monday: %v", err)
	}
	if collects != 3 || int64(energy) != 3*cost {
		t.Fatalf("today's tasks counted %d collects and %d energy, want 3 and %d", collects, energy, 3*cost)
	}
}

// A raid is the raider's deed, and a defence that held is the defender's.
func TestARaidCountsForBothSides(t *testing.T) {
	w := newWorld(t)

	// A raid won: the raider is far stronger.
	att, def := w.player(12, 0), w.player(12, 1_000_000)
	w.exec(`UPDATE app.players SET stat_attack = 5000, stat_defense = 5000 WHERE id = $1`, att.ID)
	att = w.reload(att.ID)
	res, err := w.d.Attack(w.ctx, att.ID, def.ID, att.ActionSeq+1, false)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Won {
		t.Fatal("setup: a raider with 5000 in every stat lost")
	}
	life := deedsOf(w, att.ID)[deeds.ScopeLife][0]
	if life["raids"] != 1 || life["raid_wins"] != 1 || life["gold_stolen"] != res.GoldStolen || life["energy"] <= 0 {
		t.Fatalf("the raider's lifetime after a win: %v (stole %d)", life, res.GoldStolen)
	}
	if life["revenge_wins"] != 0 {
		t.Fatalf("an ordinary raid counted as revenge: %v", life)
	}
	if held := deedsOf(w, def.ID)[deeds.ScopeLife][0]["defenses_held"]; held != 0 {
		t.Fatalf("a defence that fell counted as held (%d)", held)
	}
	var wins int32
	day := pgtype.Date{Time: w.now.Truncate(24 * time.Hour), Valid: true}
	if err := pool.QueryRow(w.ctx, `SELECT wins FROM app.player_quests WHERE player_id = $1 AND day = $2`,
		att.ID, day).Scan(&wins); err != nil || wins != 1 {
		t.Fatalf("today's tasks after a win: %d wins (%v), want 1", wins, err)
	}

	// A defence that held: the defender is far stronger.
	att2, def2 := w.player(12, 0), w.player(12, 1_000_000)
	w.exec(`UPDATE app.players SET stat_attack = 5000, stat_defense = 5000 WHERE id = $1`, def2.ID)
	res, err = w.d.Attack(w.ctx, att2.ID, def2.ID, att2.ActionSeq+1, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Won {
		t.Fatal("setup: a raider beat a defender with 5000 in every stat")
	}
	life = deedsOf(w, att2.ID)[deeds.ScopeLife][0]
	if life["raids"] != 1 || life["raid_wins"] != 0 {
		t.Fatalf("the raider's lifetime after a loss: %v", life)
	}
	held := deedsOf(w, def2.ID)
	for _, scope := range []string{deeds.ScopeLife, deeds.ScopeWeek, deeds.ScopeUWeek} {
		n := int64(0)
		for _, row := range held[scope] {
			n += row["defenses_held"]
		}
		if n != 1 {
			t.Errorf("the defender's %s holds %d defences, want 1", scope, n)
		}
	}
}

// A counter that cannot be written costs the tick, never the action.
func TestAFailedDeedDoesNotFailTheAction(t *testing.T) {
	w := newWorld(t)
	w.exec(`CREATE FUNCTION app.itest_refuse_deeds() RETURNS trigger LANGUAGE plpgsql AS
	        $$ BEGIN RAISE EXCEPTION 'itest: the deeds table refuses writes'; END $$`)
	w.exec(`CREATE TRIGGER itest_refuse_deeds BEFORE INSERT OR UPDATE ON app.player_deeds
	        FOR EACH ROW EXECUTE FUNCTION app.itest_refuse_deeds()`)
	t.Cleanup(func() {
		w.exec(`DROP TRIGGER IF EXISTS itest_refuse_deeds ON app.player_deeds`)
		w.exec(`DROP FUNCTION IF EXISTS app.itest_refuse_deeds()`)
	})

	p := w.player(1, 0)
	res, err := w.d.Collect(w.ctx, p.ID, "grapes", p.ActionSeq+1)
	if err != nil {
		t.Fatalf("a failing counter failed the collect: %v", err)
	}
	if w.reload(p.ID).Gold != res.GoldGained {
		t.Fatalf("the collect did not land")
	}
	// The savepoint holds the counters together: today's tasks and the deeds
	// are one step, so neither is half-written.
	var n int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.player_quests WHERE player_id = $1`,
		p.ID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("today's tasks were written while the deeds were refused (%d rows)", n)
	}
}
