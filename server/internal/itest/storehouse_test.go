//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The estates fill the storehouse, not the purse: up to its capacity and no
// further, carried to the purse whole or to the vault less the fee, never twice.
func TestTheStorehouseFillsAndIsCarriedIn(t *testing.T) {
	w := newWorld(t)
	p := w.player(30, 0)

	// The first look stores the rate and the capacity.
	snap, err := w.d.GetState(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	sh := snap.Storehouse
	if sh.PerHourMilli <= 0 || sh.CapMilli <= 0 || sh.Hours != 8 || snap.Player.TaxMilliPerHour != 0 {
		t.Fatalf("a level 30 lord's storehouse: %+v (player tax rate %d; want 0 for old builds)", sh, snap.Player.TaxMilliPerHour)
	}
	if sh.CapMilli != estates.StorehouseCap(sh.PerHourMilli, 8*3600) {
		t.Fatalf("capacity %d for %d an hour; want 8 hours of it", sh.CapMilli, sh.PerHourMilli)
	}

	// Four hours on, it holds four hours, and the purse has not moved.
	w.now = w.now.Add(4 * time.Hour)
	snap, _ = w.d.GetState(w.ctx, p.ID)
	if got, want := snap.Storehouse.Milli, sh.PerHourMilli*4; got < want-1 || got > want+1 {
		t.Fatalf("after four hours it holds %d; want %d", got, want)
	}
	if snap.Player.Gold != "0" {
		t.Fatalf("the purse moved on its own: %s", snap.Player.Gold)
	}

	// A day on, it is full and holds no more.
	w.now = w.now.Add(20 * time.Hour)
	snap, _ = w.d.GetState(w.ctx, p.ID)
	if !snap.Storehouse.Full || snap.Storehouse.Milli != sh.CapMilli || snap.Storehouse.FullIn != 0 {
		t.Fatalf("a day away: %+v; want full at %d", snap.Storehouse, sh.CapMilli)
	}

	// Carried to the purse: every whole gold, once.
	p = w.reload(p.ID)
	res, err := w.d.CarryStorehouse(w.ctx, p.ID, service.StorehouseToPurse, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if res.Carried != sh.CapMilli/1000 || w.reload(p.ID).Gold != res.Carried {
		t.Fatalf("carried %d, purse %d; want %d", res.Carried, w.reload(p.ID).Gold, sh.CapMilli/1000)
	}
	if res.Snapshot.Storehouse.Gold != 0 {
		t.Fatalf("after the carry it still holds %d", res.Snapshot.Storehouse.Gold)
	}
	p = w.reload(p.ID)
	if _, err := w.d.CarryStorehouse(w.ctx, p.ID, service.StorehouseToPurse, p.ActionSeq+1); !errors.Is(err, service.ErrStorehouseEmpty) {
		t.Fatalf("an empty storehouse carried: %v", err)
	}
	if _, err := w.d.CarryStorehouse(w.ctx, p.ID, "cellar", p.ActionSeq+1); !errors.Is(err, service.ErrBadDestination) {
		t.Fatalf("a carry to the cellar: %v", err)
	}

	// Two hours on, carried to the vault: less the deposit fee, the purse untouched.
	w.now = w.now.Add(2 * time.Hour)
	before := w.reload(p.ID)
	res, err = w.d.CarryStorehouse(w.ctx, p.ID, service.StorehouseToTreasury, before.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	after := w.reload(p.ID)
	fee := res.Carried * w.d.Config.Progression.Treasury.DepositFeeBP / 10000
	if res.Fee != fee || res.Banked != res.Carried-fee || after.TreasuryGold-before.TreasuryGold != res.Banked ||
		after.Gold != before.Gold {
		t.Fatalf("to the vault: %+v; vault %d -> %d, purse %d -> %d", res, before.TreasuryGold, after.TreasuryGold, before.Gold, after.Gold)
	}
	var rows int
	_ = pool.QueryRow(w.ctx, `SELECT count(*) FROM app.gold_ledger WHERE player_id = $1 AND reason = 'storehouse'`, p.ID).Scan(&rows)
	if rows != 2 {
		t.Fatalf("%d storehouse rows in the gold ledger; want one per carry", rows)
	}
}

// A lord below the vault's level cannot carry to it; one who has not played
// since cannot be refused their purse.
func TestTheVaultOpensAtItsLevel(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	if _, err := w.d.GetState(w.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	w.now = w.now.Add(8 * time.Hour)
	p = w.reload(p.ID)
	if _, err := w.d.CarryStorehouse(w.ctx, p.ID, service.StorehouseToTreasury, p.ActionSeq+1); !errors.Is(err, service.ErrLevelTooLow) {
		t.Fatalf("a level 1 lord carried to the vault: %v", err)
	}
	if _, err := w.d.CarryStorehouse(w.ctx, p.ID, service.StorehouseToPurse, p.ActionSeq+1); err != nil {
		t.Fatalf("a level 1 lord's purse: %v", err)
	}
}

// A change of rate is settled at the old rate first, and the database's sum is
// game/estates.Fill's.
func TestARateChangeSettlesAtTheOldRate(t *testing.T) {
	w := newWorld(t)
	p := w.player(30, 5_000_000)
	snap, _ := w.d.GetState(w.ctx, p.ID)
	old := snap.Storehouse

	// Three hours at the old rate, then a level: the rate rises.
	w.now = w.now.Add(3 * time.Hour)
	w.exec(`UPDATE app.players SET level = 40 WHERE id = $1`, p.ID)
	snap, _ = w.d.GetState(w.ctx, p.ID)
	if snap.Storehouse.PerHourMilli <= old.PerHourMilli {
		t.Fatalf("level 40 fills at %d, level 30 at %d", snap.Storehouse.PerHourMilli, old.PerHourMilli)
	}
	if got, want := snap.Storehouse.Milli, old.PerHourMilli*3; got < want-1 || got > want+1 {
		t.Fatalf("the three hours before the level hold %d; want %d, at the old rate", got, want)
	}
	row := w.reload(p.ID)
	if row.StorehouseMilli != snap.Storehouse.Milli || row.TaxMilliPerHour != snap.Storehouse.PerHourMilli {
		t.Fatalf("the row says %d at %d; the snapshot %d at %d", row.StorehouseMilli, row.TaxMilliPerHour,
			snap.Storehouse.Milli, snap.Storehouse.PerHourMilli)
	}

	// The SQL settle and Fill agree, across a fill that crosses the capacity,
	// from a storehouse already over it, and a clock gone back.
	for _, c := range []struct {
		milli, capMilli int64
		ago             time.Duration
	}{{0, 90_000, 30 * time.Minute}, {50_000, 90_000, 20 * time.Hour}, {120_000, 90_000, 5 * time.Hour}, {1_000, 90_000, -time.Hour}} {
		at := w.now.Add(-c.ago)
		w.exec(`UPDATE app.players SET storehouse_milli = $2, storehouse_cap_milli = $3, storehouse_at = $4,
		        tax_milli_per_hour = 18_000 WHERE id = $1`, p.ID, c.milli, c.capMilli, at)
		want := estates.Fill(estates.Storehouse{Milli: c.milli, At: at}, 18_000, c.capMilli, w.now)
		// The real query, settling at the stored pair and storing a new one.
		if err := w.q.RefreshStorehouse(w.ctx, sqlcdb.RefreshStorehouseParams{
			ID: p.ID, Now: w.now, Rate: 36_000, CapMilli: 180_000,
		}); err != nil {
			t.Fatal(err)
		}
		got := w.reload(p.ID)
		if got.TaxMilliPerHour != 36_000 || got.StorehouseCapMilli != 180_000 {
			t.Fatalf("the new pair was not stored: %d, %d", got.TaxMilliPerHour, got.StorehouseCapMilli)
		}
		if got.StorehouseMilli != want.Milli || !got.StorehouseAt.Equal(want.At) {
			t.Fatalf("from %d over %s: the database settles %d at %s; Fill %d at %s", c.milli, c.ago,
				got.StorehouseMilli, got.StorehouseAt, want.Milli, want.At)
		}
	}
}
