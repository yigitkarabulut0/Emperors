package cart

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

const four = 4 * time.Hour

var t0 = time.Date(2026, 9, 15, 8, 0, 0, 0, time.UTC)

// A cart every four hours, three at most, and the part of an interval already
// served carries over.
func TestCartsArriveOnTheirClock(t *testing.T) {
	cases := []struct {
		name      string
		y         Yard
		after     time.Duration
		wantStock int
		wantAt    time.Time
		wantNext  time.Duration
	}{
		{"none yet", Yard{0, t0}, 3 * time.Hour, 0, t0, time.Hour},
		{"one arrived", Yard{0, t0}, 5 * time.Hour, 1, t0.Add(four), 3 * time.Hour},
		{"two, and the rest carries", Yard{1, t0}, 9 * time.Hour, 3, t0.Add(9 * time.Hour), 0},
		{"a day away fills the yard, no more", Yard{0, t0}, 24 * time.Hour, 3, t0.Add(24 * time.Hour), 0},
		{"a full yard waits", Yard{3, t0}, 30 * time.Hour, 3, t0.Add(30 * time.Hour), 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			now := t0.Add(c.after)
			got := Settle(c.y, 3, four, now)
			if got.Stock != c.wantStock || !got.At.Equal(c.wantAt) {
				t.Fatalf("settled %+v, want stock %d at %v", got, c.wantStock, c.wantAt)
			}
			if next := NextIn(got, 3, four, now); next != c.wantNext {
				t.Fatalf("next in %v, want %v", next, c.wantNext)
			}
			// Settling twice changes nothing.
			if again := Settle(got, 3, four, now); again != got {
				t.Fatalf("settling twice moved the yard: %+v then %+v", got, again)
			}
		})
	}
}

// Taking from a full yard starts the clock then; from a yard that is not full
// the clock runs on, so opening a cart never delays the next.
func TestTakingACartKeepsTheClockHonest(t *testing.T) {
	now := t0.Add(13 * time.Hour)
	full := Settle(Yard{0, t0}, 3, four, now)
	y, ok := Take(full, 3, now)
	if !ok || y.Stock != 2 || !y.At.Equal(now) {
		t.Fatalf("from a full yard: %+v %v", y, ok)
	}
	if NextIn(y, 3, four, now) != four {
		t.Fatalf("the next cart should be a whole interval away, is %v", NextIn(y, 3, four, now))
	}

	part := Settle(Yard{0, t0}, 3, four, t0.Add(5*time.Hour)) // one waiting, an hour into the next
	y, ok = Take(part, 3, t0.Add(5*time.Hour))
	if !ok || y.Stock != 0 || !y.At.Equal(t0.Add(four)) {
		t.Fatalf("from a part yard: %+v %v", y, ok)
	}
	if _, ok := Take(Yard{0, t0}, 3, t0); ok {
		t.Fatal("took a cart from an empty yard")
	}
}

// The same seed draws the same prize, and over many carts each row comes up
// about as often as its published odds say.
func TestTheDrawFollowsThePublishedOdds(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	odds := b.Retention.Cart.Odds
	secret := []byte("test")
	first := Draw(game.SeedForString(secret, "lord", 7), odds)
	if again := Draw(game.SeedForString(secret, "lord", 7), odds); again != first {
		t.Fatalf("the seventh cart drew %d and then %d", first, again)
	}
	const n = 200000
	counts := make([]int, len(odds))
	for i := 0; i < n; i++ {
		counts[Draw(game.SeedForString(secret, "lord", uint64(i)), odds)]++
	}
	for i, o := range odds {
		got := float64(counts[i]) * 10000 / n
		if d := got - float64(o.BP); d > 60 || d < -60 {
			t.Errorf("%s came up %.0f bp of the time; the odds say %d", o.ID, got, o.BP)
		}
	}
}
