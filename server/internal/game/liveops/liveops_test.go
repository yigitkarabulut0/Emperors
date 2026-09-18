package liveops

import (
	"fmt"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t *testing.T) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Every hour rolls the same event on every call; no event runs twice in a
// row; over many hours each comes up about as often as its published chance.
func TestTheHourlyRollIsFairAndNeverRepeats(t *testing.T) {
	b := cfg(t)
	secret := []byte("test")
	h0 := Hour(time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC))
	if HourlyAt(secret, b.LiveOps.Hourly, nil, h0) != HourlyAt(secret, b.LiveOps.Hourly, nil, h0) {
		t.Fatal("an hour rolled two different events")
	}
	counts := map[string]int{}
	prev := ""
	const n = 20000
	for i := int64(0); i < n; i++ {
		id := HourlyAt(secret, b.LiveOps.Hourly, nil, h0+i)
		if id == prev && id != gameconfig.HourlyNone {
			t.Fatalf("hour %d repeated %s", i, id)
		}
		prev = id
		counts[id]++
	}
	for _, e := range b.LiveOps.Hourly.Table {
		got := float64(counts[e.ID]) * 10000 / n
		// No-repeat moves a little chance from the event just run to the rest.
		if d := got - float64(e.BP); d > 250 || d < -250 {
			t.Errorf("%s came up %.0f bp of hours; published %d", e.ID, got, e.BP)
		}
	}
}

// The panel's override is the hour's event, and the hour after it still does
// not repeat it.
func TestAnOverrideDecidesItsHour(t *testing.T) {
	b := cfg(t)
	secret := []byte("test")
	h := Hour(time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC))
	ov := map[int64]string{h: "gold_rush"}
	if got := HourlyAt(secret, b.LiveOps.Hourly, ov, h); got != "gold_rush" {
		t.Fatalf("forced gold_rush, got %s", got)
	}
	if got := HourlyAt(secret, b.LiveOps.Hourly, ov, h+1); got == "gold_rush" {
		t.Fatal("the hour after a forced event repeated it")
	}
	ov[h] = gameconfig.HourlyNone
	if got := HourlyAt(secret, b.LiveOps.Hourly, ov, h); got != gameconfig.HourlyNone {
		t.Fatalf("skipped hour rolled %s", got)
	}
}

// Seasons are 28 days from their Monday; before the first is season 0.
func TestSeasonsAreWholeWeeksFromTheirEpoch(t *testing.T) {
	sc := cfg(t).LiveOps.Season
	s := SeasonAt(sc, time.Date(2026, 9, 15, 9, 0, 0, 0, time.UTC))
	if s.Number != 1 || !s.Start.Equal(time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)) ||
		!s.End.Equal(time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("mid-September: %+v", s)
	}
	if s2 := SeasonAt(sc, time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)); s2.Number != 2 {
		t.Fatalf("the first instant of season 2: %+v", s2)
	}
	if s0 := SeasonAt(sc, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)); s0.Number != 0 {
		t.Fatalf("before the epoch: %+v", s0)
	}
	if n := SeasonNumbered(sc, 2); !n.Start.Equal(time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("season 2 numbered: %+v", n)
	}
}

// A point for every five energy keeps its fractions; tiers stop at the last.
func TestPointsKeepTheirFractions(t *testing.T) {
	src := []gameconfig.PointSource{{Deed: "energy", Points: 1, Per: 5}, {Deed: "raid_wins", Points: 15, Per: 1}}
	if got := PointsMilli(src, map[string]int64{"energy": 3}); got != 600 {
		t.Fatalf("3 energy earned %d milli-points; want 600", got)
	}
	if got := PointsMilli(src, map[string]int64{"energy": 10, "raid_wins": 2}); got != 32000 {
		t.Fatalf("10 energy and 2 wins earned %d; want 32000", got)
	}
	if Tier(119, 120, 50) != 0 || Tier(120, 120, 50) != 1 || Tier(1e9, 120, 50) != 50 {
		t.Fatal("tiers")
	}
}

// A run's first day is day 1; the 25th hour is day 2.
func TestDaysCountFromTheRunsOwnStart(t *testing.T) {
	start := time.Date(2026, 9, 15, 18, 0, 0, 0, time.UTC)
	if DayOf(start, start.Add(-time.Minute)) != 0 || DayOf(start, start) != 1 ||
		DayOf(start, start.Add(23*time.Hour+59*time.Minute)) != 1 || DayOf(start, start.Add(24*time.Hour)) != 2 {
		t.Fatal("festival days")
	}
}

// Rungs reached, and which of them are still open.
func TestLaddersAndTheirClaims(t *testing.T) {
	if Reached([]int64{10, 100, 500, 2000}, 99) != 1 || Reached([]int64{10, 100}, 100) != 2 || Reached([]int64{10}, 0) != 0 {
		t.Fatal("reached")
	}
	open := Open(4, Mask([]int{0, 2}))
	if len(open) != 2 || open[0] != 1 || open[1] != 3 {
		t.Fatalf("open %v; want [1 3]", open)
	}
	if len(Open(50, Mask(Open(50, 0)))) != 0 {
		t.Fatal("fifty tiers claimed still left one open")
	}
}

// Places pay their row; past the last row, nothing.
func TestPlacesPayTheirRow(t *testing.T) {
	ranks := cfg(t).LiveOps.Ranks.Weekly[0].Rewards
	if g := PlaceReward(ranks, 1); g == nil || g.Diamonds != 50 {
		t.Fatalf("first place: %+v", g)
	}
	if g := PlaceReward(ranks, 3); g == nil || g.Diamonds != 30 {
		t.Fatalf("third place: %+v", g)
	}
	if g := PlaceReward(ranks, 4); g == nil || g.Diamonds != 15 {
		t.Fatalf("fourth place: %+v", g)
	}
	if PlaceReward(ranks, 51) != nil || PlaceReward(ranks, 0) != nil {
		t.Fatal("past the board, or no place, paid")
	}
}

// The season's nobles: each lord their highest rank, the shares rounded up,
// and a Knight anywhere on the board whose Charter reached its tier.
func TestNobilityGivesEachLordTheirHighestRank(t *testing.T) {
	ranks := cfg(t).LiveOps.Ranks.Nobility
	var board []Standing
	for i := 1; i <= 200; i++ {
		tier := 0
		if i == 3 || i == 150 {
			tier = 30
		}
		board = append(board, Standing{Key: fmt.Sprint(i), Place: i, Tier: tier})
	}
	got := Nobility(ranks, board)
	want := map[string]string{"1": "emperor", "2": "prince", "3": "prince", "5": "prince", "6": "duke", "25": "duke",
		"26": "baron", "40": "baron", "41": "", "150": "knight", "200": ""}
	// Count is the top 5% of 200 -- ten places, all of them already Princes and Dukes.
	for k, w := range want {
		if got[k] != w {
			t.Errorf("place %s: %q, want %q", k, got[k], w)
		}
	}
	small := Nobility(ranks, []Standing{{Key: "a", Place: 1}, {Key: "b", Place: 2}})
	if small["a"] != "emperor" || small["b"] != "prince" {
		t.Fatalf("a two-lord season: %v", small)
	}
}
