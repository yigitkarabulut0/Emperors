//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// A single collect counts toward today's tasks, as a batch always did.
func TestASingleCollectCountsTowardQuests(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)

	if _, err := w.d.Collect(w.ctx, p.ID, "grapes", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	var collects int32
	day := pgtype.Date{Time: w.now.Truncate(24 * time.Hour), Valid: true}
	if err := pool.QueryRow(w.ctx,
		`SELECT collects FROM app.player_quests WHERE player_id = $1 AND day = $2`,
		p.ID, day).Scan(&collects); err != nil {
		t.Fatalf("no quest row after a single collect: %v", err)
	}
	if collects != 1 {
		t.Fatalf("one collect counted %d toward today's tasks", collects)
	}
}

// A quest tick that fails no longer takes the collect down with it.
//
// Before the savepoint, the swallowed error still aborted the transaction in
// Postgres and the COMMIT came back as a rollback: the player's collect failed
// because a counter could not be written.
func TestAFailedQuestTickDoesNotFailTheAction(t *testing.T) {
	w := newWorld(t)
	w.exec(`CREATE FUNCTION app.itest_refuse() RETURNS trigger LANGUAGE plpgsql AS
	        $$ BEGIN RAISE EXCEPTION 'itest: the quest table refuses writes'; END $$`)
	w.exec(`CREATE TRIGGER itest_refuse BEFORE INSERT OR UPDATE ON app.player_quests
	        FOR EACH ROW EXECUTE FUNCTION app.itest_refuse()`)
	t.Cleanup(func() {
		w.exec(`DROP TRIGGER IF EXISTS itest_refuse ON app.player_quests`)
		w.exec(`DROP FUNCTION IF EXISTS app.itest_refuse()`)
	})

	p := w.player(1, 0)
	res, err := w.d.Collect(w.ctx, p.ID, "grapes", p.ActionSeq+1)
	if err != nil {
		t.Fatalf("a failing quest tick failed the collect: %v", err)
	}
	if res.GoldGained <= 0 || w.reload(p.ID).Gold != res.GoldGained {
		t.Fatalf("the collect did not land: gained %d, purse %d", res.GoldGained, w.reload(p.ID).Gold)
	}
	batch, err := w.d.CollectBatch(w.ctx, p.ID, []string{"grapes", "grapes"}, p.ActionSeq+2)
	if err != nil {
		t.Fatalf("a failing quest tick failed the batch: %v", err)
	}
	if batch.Applied != 2 {
		t.Fatalf("the batch applied %d of 2", batch.Applied)
	}
}

// raidReady makes two lords who can fight each other.
func raidReady(w *world) (att, def sqlcdb.AppPlayer) {
	return w.player(12, 0), w.player(12, 1_000_000)
}

// An ordinary raid ends the raider's own shield.
func TestRaidingEndsTheRaidersShield(t *testing.T) {
	w := newWorld(t)
	att, def := raidReady(w)
	w.exec(`UPDATE app.players SET shield_until = $2 WHERE id = $1`, att.ID, w.now.Add(8*time.Hour))

	if _, err := w.d.Attack(w.ctx, att.ID, def.ID, att.ActionSeq+1, false); err != nil {
		t.Fatal(err)
	}
	if s := w.reload(att.ID).ShieldUntil; s != nil && s.After(w.now) {
		t.Fatalf("the raider is still shielded until %v after raiding", *s)
	}
}

// A revenge strike keeps the avenger's shield.
func TestRevengeKeepsTheAvengersShield(t *testing.T) {
	w := newWorld(t)
	avenger, raider := raidReady(w)
	until := w.now.Add(8 * time.Hour).Truncate(time.Microsecond)
	w.exec(`UPDATE app.players SET shield_until = $2 WHERE id = $1`, avenger.ID, until)

	// The raid being answered: a stored battle and the token it earned.
	battle := uuid.New()
	if _, err := w.q.InsertBattle(w.ctx, sqlcdb.InsertBattleParams{
		ID: battle, AttackerID: raider.ID, DefenderID: avenger.ID, Seed: 1,
		ConfigVersion: 1, AttackerWon: true, Rounds: 1, Replay: []byte(`{}`), Kind: "raid",
	}); err != nil {
		t.Fatal(err)
	}
	if err := w.q.GrantRevenge(w.ctx, sqlcdb.GrantRevengeParams{
		BattleID: battle, PlayerID: avenger.ID, TargetID: raider.ID,
		ExpiresAt: w.now.Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	avenger = w.reload(avenger.ID)
	if _, err := w.d.Attack(w.ctx, avenger.ID, raider.ID, avenger.ActionSeq+1, true); err != nil {
		t.Fatal(err)
	}
	s := w.reload(avenger.ID).ShieldUntil
	if s == nil || !s.Equal(until) {
		t.Fatalf("a revenge strike changed the avenger's shield to %v, want %v kept", s, until)
	}
}

// Level-up diamonds pay a refund debt before they reach the purse, and the
// ledger records the whole grant.
func TestLevelUpDiamondsRepayDebtFirst(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	w.exec(`UPDATE app.players SET diamond_debt = 7 WHERE id = $1`, p.ID)

	grapes := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "grapes"
		}
		return out
	}
	// Level 1 -> 2 is sixteen experience, eight grapes: one level, five diamonds.
	if _, err := w.d.CollectBatch(w.ctx, p.ID, grapes(8), p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	p = w.reload(p.ID)
	if p.Level != 2 || p.Diamonds != 0 || p.DiamondDebt != 2 {
		t.Fatalf("after one level: level %d, %d diamonds, owes %d; want 2, 0, 2",
			p.Level, p.Diamonds, p.DiamondDebt)
	}
	var delta, gross, debtAfter int64
	if err := pool.QueryRow(w.ctx, `SELECT delta, gross, debt_after FROM app.diamond_ledger
		WHERE player_id = $1 ORDER BY id DESC LIMIT 1`, p.ID).Scan(&delta, &gross, &debtAfter); err != nil {
		t.Fatal(err)
	}
	if delta != 0 || gross != 5 || debtAfter != 2 {
		t.Fatalf("ledger row: delta %d gross %d debt_after %d; want 0, 5, 2", delta, gross, debtAfter)
	}

	// Level 2 -> 3 is thirty-two experience: the next five clear the debt and
	// three reach the purse.
	if _, err := w.d.CollectBatch(w.ctx, p.ID, grapes(16), p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	p = w.reload(p.ID)
	if p.Level != 3 || p.Diamonds != 3 || p.DiamondDebt != 0 {
		t.Fatalf("after the second level: level %d, %d diamonds, owes %d; want 3, 3, 0",
			p.Level, p.Diamonds, p.DiamondDebt)
	}
}

// Every diamond spend lands in the ledger with its reason.
func TestDiamondSpendsAreLedgered(t *testing.T) {
	w := newWorld(t)
	p := w.player(12, 0)
	w.exec(`UPDATE app.players SET diamonds = 200, energy_milli = 0 WHERE id = $1`, p.ID)
	// The balance set by hand enters the ledger the way the migration's opening
	// rows did, so the reconciliation holds.
	w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
	        VALUES ($1, 200, 200, 200, 'opening_balance', 'opening')`, p.ID)
	p = w.reload(p.ID)

	if _, err := w.d.BuyStoreGood(w.ctx, p.ID, "energy_refill", "", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	p = w.reload(p.ID)
	if _, err := w.d.BuyStoreGood(w.ctx, p.ID, "shield", "", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	p = w.reload(p.ID)
	if _, err := w.d.RerollShop(w.ctx, p.ID, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}

	rows, err := pool.Query(w.ctx, `SELECT reason, gross FROM app.diamond_ledger
		WHERE player_id = $1 AND class = 'spent' ORDER BY id`, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var reason string
		var gross int64
		if err := rows.Scan(&reason, &gross); err != nil {
			t.Fatal(err)
		}
		if gross >= 0 {
			t.Errorf("spend %s recorded gross %d, want negative", reason, gross)
		}
		got = append(got, reason)
	}
	want := []string{"energy_refill", "shield", "market_reroll"}
	if len(got) != len(want) {
		t.Fatalf("spends in the ledger: %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("spends in the ledger: %v, want %v", got, want)
		}
	}
}

// The daily square is ledgered as earned.
func TestTheDailySquareIsLedgered(t *testing.T) {
	w := newWorld(t)
	p := w.player(3, 0)
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); err != nil {
		t.Fatal(err)
	}
	var reason, class string
	var gross int64
	if err := pool.QueryRow(w.ctx, `SELECT reason, class, gross FROM app.diamond_ledger
		WHERE player_id = $1`, p.ID).Scan(&reason, &class, &gross); err != nil {
		t.Fatal(err)
	}
	if reason != "daily_login" || class != "earned" || gross != w.d.Config.Retention.Calendar.Squares[0].Grant.Diamonds {
		t.Fatalf("daily square ledgered as %s/%s %d", reason, class, gross)
	}
}

// The panel cannot take diamonds a player does not have, and says why.
func TestThePanelCannotRemovePastZero(t *testing.T) {
	w := newWorld(t)
	p := w.player(5, 0)
	w.exec(`UPDATE app.players SET diamonds = 20 WHERE id = $1`, p.ID)
	w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
	        VALUES ($1, 20, 20, 20, 'opening_balance', 'opening')`, p.ID)

	boss, err := w.q.CreateAdminUser(w.ctx, sqlcdb.CreateAdminUserParams{
		Username: "it" + uuid.NewString()[:8], PasswordHash: "x", Role: "owner",
	})
	if err != nil {
		t.Fatal(err)
	}
	who := &admin.Identity{ID: boss.ID, Username: boss.Username, Role: "owner"}
	svc := &admin.Service{Pool: pool}

	if _, err := svc.AdjustPlayer(w.ctx, who, p.ID, 0, -50, 0, 0, "itest"); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("removing 50 from 20 diamonds: %v, want out of range", err)
	}
	row, err := svc.AdjustPlayer(w.ctx, who, p.ID, 0, 30, 0, 0, "itest")
	if err != nil {
		t.Fatal(err)
	}
	if row.Diamonds != 50 {
		t.Fatalf("granting 30 to 20 left %d", row.Diamonds)
	}
	if _, err := svc.AdjustPlayer(w.ctx, who, p.ID, 0, -50, 0, 0, "itest"); err != nil {
		t.Fatalf("removing all 50: %v", err)
	}
}

// Deleting an account keeps its diamond history (no foreign key), which is
// what a refund arriving later has to read.
func TestTheLedgerOutlivesTheAccount(t *testing.T) {
	w := newWorld(t)
	p := w.player(3, 0)
	if _, err := w.d.ClaimDaily(w.ctx, p.ID, ""); err != nil {
		t.Fatal(err)
	}
	w.exec(`DELETE FROM app.players WHERE id = $1`, p.ID)
	var n int
	if err := pool.QueryRow(w.ctx, `SELECT count(*) FROM app.diamond_ledger WHERE player_id = $1`,
		p.ID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("after deletion the ledger holds %d rows for the account, want 1", n)
	}
}

// Three refills a day at 20, 30 and 45, then none until the player's midnight.
func TestRefillsAreThreeADay(t *testing.T) {
	w := newWorld(t)
	p := w.player(12, 0)
	w.exec(`UPDATE app.players SET diamonds = 500 WHERE id = $1`, p.ID)
	w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
	        VALUES ($1, 500, 500, 500, 'opening_balance', 'opening')`, p.ID)

	buy := func() error {
		w.exec(`UPDATE app.players SET energy_milli = 0, energy_updated_at = $2 WHERE id = $1`, p.ID, w.now)
		p = w.reload(p.ID)
		_, err := w.d.BuyStoreGood(w.ctx, p.ID, "energy_refill", "", p.ActionSeq+1)
		return err
	}
	for i, want := range []int64{20, 30, 45} {
		before := w.reload(p.ID).Diamonds
		if err := buy(); err != nil {
			t.Fatalf("refill %d: %v", i+1, err)
		}
		if paid := before - w.reload(p.ID).Diamonds; paid != want {
			t.Fatalf("refill %d cost %d, want %d", i+1, paid, want)
		}
	}
	if err := buy(); !errors.Is(err, service.ErrRefillsExhausted) {
		t.Fatalf("a fourth refill: %v, want refills exhausted", err)
	}
	store, err := w.d.GetStore(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if g := store.Goods[0]; g.ID != "energy_refill" || g.Useful || g.RefillsUsed != 3 || g.RefillsLimit != 3 {
		t.Fatalf("store after the day's refills: %+v", g)
	}

	// The next local day starts the ladder again at its first price.
	w.now = w.now.Add(24 * time.Hour)
	before := w.reload(p.ID).Diamonds
	if err := buy(); err != nil {
		t.Fatalf("the next day's first refill: %v", err)
	}
	if paid := before - w.reload(p.ID).Diamonds; paid != 20 {
		t.Fatalf("the next day's first refill cost %d, want 20", paid)
	}
}

// The market rerolls at most the day's allowance, whatever the purse holds, and
// the count starts again on the lord's next day.
func TestTheMarketRerollsADayAtMost(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	w.exec(`UPDATE app.players SET diamonds = 50000 WHERE id = $1`, p.ID)
	w.exec(`INSERT INTO app.diamond_ledger (player_id, delta, gross, balance_after, reason, class)
	        VALUES ($1, 50000, 50000, 50000, 'opening_balance', 'opening')`, p.ID)
	cap := w.d.Config.Items.Shop.RerollsPerDay
	if cap <= 0 {
		t.Fatal("no daily reroll cap in the balance")
	}
	for i := 0; i < cap; i++ {
		p = w.reload(p.ID)
		v, err := w.d.RerollShop(w.ctx, p.ID, p.ActionSeq+1)
		if err != nil {
			t.Fatalf("reroll %d of %d: %v", i+1, cap, err)
		}
		if v.RerollsLeft != cap-i-1 || v.RerollsPerDay != cap {
			t.Fatalf("after reroll %d: %d left of %d", i+1, v.RerollsLeft, v.RerollsPerDay)
		}
	}
	p = w.reload(p.ID)
	before := p.Diamonds
	if _, err := w.d.RerollShop(w.ctx, p.ID, p.ActionSeq+1); !errors.Is(err, service.ErrRerollsExhausted) {
		t.Fatalf("reroll %d: %v; want the day's allowance spent", cap+1, err)
	}
	if after := w.reload(p.ID); after.Diamonds != before || after.ActionSeq != p.ActionSeq {
		t.Fatalf("a refused reroll moved the purse (%d -> %d) or the sequence", before, after.Diamonds)
	}
	// A new window does not reset the day's count; a new day does.
	w.now = w.now.Add(10 * time.Minute)
	if v, _ := w.d.GetShop(w.ctx, p.ID); v.RerollsLeft != 0 {
		t.Fatalf("a new window gave back rerolls: %d", v.RerollsLeft)
	}
	w.now = w.now.Add(24 * time.Hour)
	p = w.reload(p.ID)
	v, err := w.d.RerollShop(w.ctx, p.ID, p.ActionSeq+1)
	if err != nil || v.RerollsLeft != cap-1 {
		t.Fatalf("the next day: %+v, %v", v, err)
	}
}
