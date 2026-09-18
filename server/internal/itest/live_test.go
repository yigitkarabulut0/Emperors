//go:build integration

package itest

import (
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// An event scheduled from the panel is announced a day ahead, changes nothing
// until it starts, and is live -- with what it is worth to this lord and when
// it ends -- once it has.
func TestAScheduledEventIsAnnouncedThenLive(t *testing.T) {
	w := newWorld(t)
	boosts := service.NewBoosts(pool, slog.Default(), func() time.Time { return w.now })
	w.d.Boosts = boosts
	svc, who := designer(t, w)
	svc.Boosts = boosts

	if _, err := svc.CreateBoost(w.ctx, who, gameconfig.BucketXP, 5000, 3, -1, "bad"); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("an event starting in the past: %v", err)
	}
	row, err := svc.CreateBoost(w.ctx, who, gameconfig.BucketXP, 5000, 3, 2, "a scheduled test")
	if err != nil || !row.Scheduled || row.Live {
		t.Fatalf("a scheduled event: %+v, %v", row, err)
	}
	t.Cleanup(func() { _, _ = svc.RevokeBoost(w.ctx, who, row.ID) })

	p := w.player(10, 0)
	snap, err := w.d.GetState(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	var soon *service.LiveBoost
	for i := range snap.Live.Upcoming {
		if snap.Live.Upcoming[i].Bucket == gameconfig.BucketXP && snap.Live.Upcoming[i].BP == 5000 {
			soon = &snap.Live.Upcoming[i]
		}
	}
	// The panel's clock keeps whole seconds; the world's does not.
	near := func(got, want int64) bool { return got >= want-1 && got <= want }
	if soon == nil || !near(soon.StartsIn, 7200) || !near(soon.EndsIn, 7200+3*3600) {
		t.Fatalf("the announcement: %+v in %+v", soon, snap.Live.Upcoming)
	}
	for _, b := range snap.Live.Boosts {
		if b.Bucket == gameconfig.BucketXP && b.BP >= 5000 {
			t.Fatalf("a scheduled event is already live: %+v", b)
		}
	}

	// Two hours on, it has begun.
	w.now = w.now.Add(2*time.Hour + time.Minute)
	if err := boosts.Refresh(w.ctx); err != nil {
		t.Fatal(err)
	}
	snap, _ = w.d.GetState(w.ctx, p.ID)
	var live *service.LiveBoost
	for i := range snap.Live.Boosts {
		if snap.Live.Boosts[i].Bucket == gameconfig.BucketXP {
			live = &snap.Live.Boosts[i]
		}
	}
	if live == nil || live.BP < 5000 || live.EffectiveBP <= 0 || !near(live.EndsIn, 3*3600-60) {
		t.Fatalf("once begun: %+v in %+v", live, snap.Live.Boosts)
	}
}
