//go:build integration

package itest

import (
	"errors"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
)

// The dev tools move one lord's clocks and counters, and only a server that was
// given them has them.
func TestTheDevToolsMoveOneLord(t *testing.T) {
	w := newWorld(t)
	svc, who := designer(t, w)
	p, other := w.player(30, 0), w.player(30, 0)
	for _, id := range []any{p.ID, other.ID} {
		w.exec(`UPDATE app.players SET energy_milli = 0 WHERE id = $1`, id)
	}
	if _, err := w.d.GetState(w.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.GetState(w.ctx, other.ID); err != nil {
		t.Fatal(err)
	}

	// Without the tools: refused, whatever the role.
	if err := svc.DevTimeWarp(w.ctx, who, p.ID, 8); !errors.Is(err, admin.ErrNoDevTools) {
		t.Fatalf("a server without dev tools warped a lord: %v", err)
	}
	svc.Dev = w.d
	if err := svc.DevTimeWarp(w.ctx, &admin.Identity{Username: "mod", Role: "moderator"}, p.ID, 8); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator warped a lord: %v", err)
	}
	if err := svc.DevTimeWarp(w.ctx, who, p.ID, 0); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("a warp of no time: %v", err)
	}

	// Eight hours: this lord's energy and storehouse fill; the other's do not.
	if err := svc.DevTimeWarp(w.ctx, who, p.ID, 8); err != nil {
		t.Fatal(err)
	}
	snap, _ := w.d.GetState(w.ctx, p.ID)
	still, _ := w.d.GetState(w.ctx, other.ID)
	if snap.Energy.Current <= still.Energy.Current || !snap.Storehouse.Full || still.Storehouse.Gold != 0 {
		t.Fatalf("after the warp: energy %d against %d, storehouse %+v against %+v",
			snap.Energy.Current, still.Energy.Current, snap.Storehouse, still.Storehouse)
	}

	// Deeds counted as if done; an unknown one refused.
	if err := svc.DevAddDeeds(w.ctx, who, p.ID, "raid_wins", 7); err != nil {
		t.Fatal(err)
	}
	if n := w.count(`SELECT coalesce(sum(value), 0) FROM app.player_deeds WHERE player_id = $1 AND deed = 'raid_wins' AND scope = 'life'`, p.ID); n != 7 {
		t.Fatalf("raid wins counted %d; want 7", n)
	}
	if err := svc.DevAddDeeds(w.ctx, who, p.ID, "dragons_slain", 1); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("an unknown deed: %v", err)
	}

	// A job run on demand; an unknown one refused.
	if err := svc.DevRunJob(w.ctx, who, "kpi_rollup"); err != nil {
		t.Fatal(err)
	}
	if err := svc.DevRunJob(w.ctx, who, "no_such_job"); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("an unknown job: %v", err)
	}
}
