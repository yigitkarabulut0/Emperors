package service

import (
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The row shows the stretch of the ladder the player is on: the threshold whose
// bonus they hold, the one they are working toward, and the one after. At 213
// collects that is 100 / 250 / 500 -- not 250 / 500 / 1000, which read as if the
// 250 had already been reached.
func TestMasteryViewShowsTheStretchThePlayerIsOn(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	ms := b.Jobs.Milestones
	if len(ms) < 3 {
		t.Fatalf("seed ladder has %d milestones; the test needs at least three", len(ms))
	}
	last := ms[len(ms)-1]
	cases := []struct {
		collects int64
		want     MasteryView
	}{
		{0, MasteryView{0, 0, ms[0].Collects, ms[0].BonusBP, ms[1].Collects, ms[1].BonusBP}},
		{ms[0].Collects - 1, MasteryView{0, 0, ms[0].Collects, ms[0].BonusBP, ms[1].Collects, ms[1].BonusBP}},
		{ms[0].Collects, MasteryView{ms[0].Collects, ms[0].BonusBP, ms[1].Collects, ms[1].BonusBP, ms[2].Collects, ms[2].BonusBP}},
		{last.Collects - 1, MasteryView{ms[len(ms)-2].Collects, ms[len(ms)-2].BonusBP, last.Collects, last.BonusBP, 0, 0}},
		{last.Collects, MasteryView{last.Collects, last.BonusBP, 0, 0, 0, 0}},
		{last.Collects * 10, MasteryView{last.Collects, last.BonusBP, 0, 0, 0, 0}},
	}
	for _, c := range cases {
		if got := masteryView(b, c.collects); got != c.want {
			t.Errorf("collects %d: got %+v, want %+v", c.collects, got, c.want)
		}
	}
	// The user's own case, against the ladder as shipped.
	if got := masteryView(b, 213); got.Reached != 100 || got.Next != 250 || got.After != 500 {
		t.Errorf("213 collects: got %+v, want reached 100, next 250, after 500", got)
	}
}
