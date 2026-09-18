package arena

import (
	"math"
	"testing"
)

func rules() Rules {
	return Rules{Start: 1000, Floor: 800, Ceiling: 5000, K: 32, DefenderKBP: 5000, ResetBP: 5000}
}

func tiers() []Tier {
	return []Tier{
		{ID: "bronze", AtRating: 0}, {ID: "silver", AtRating: 1150},
		{ID: "gold", AtRating: 1300}, {ID: "platinum", AtRating: 1450},
		{ID: "sapphire", AtRating: 1600}, {ID: "imperial", AtRating: 1800, TopN: 50},
	}
}

// The one arithmetic property the whole ladder rests on.
//
// If the expected score is asymmetric by even a basis point, two alts trading
// attacks mint rating forever: A attacks B, then B attacks A, and the pair ends
// up richer than it started. Half-K makes the ladder non-zero-sum on purpose;
// it must not be non-zero-sum by accident as well.
func TestExpectedIsSymmetric(t *testing.T) {
	for a := 800; a <= 2400; a += 25 {
		for b := 800; b <= 2400; b += 25 {
			if got := ExpectedBP(a, b) + ExpectedBP(b, a); got != 10000 {
				t.Fatalf("ExpectedBP(%d,%d) + ExpectedBP(%d,%d) = %d, want 10000", a, b, b, a, got)
			}
		}
	}
	// And off the table's step, where the interpolation runs.
	for d := 0; d <= 900; d++ {
		if got := ExpectedBP(1500+d, 1500) + ExpectedBP(1500, 1500+d); got != 10000 {
			t.Fatalf("gap %d: the two sides sum to %d", d, got)
		}
	}
}

// The integer table is the real Elo curve, to a quarter of a per cent.
func TestTheExpectedTableMatchesElo(t *testing.T) {
	for d := 0; d <= 800; d += 5 {
		want := int64(math.Round(10000 / (1 + math.Pow(10, -float64(d)/400))))
		got := ExpectedBP(1000+d, 1000)
		if diff := got - want; diff > 25 || diff < -25 {
			t.Fatalf("gap %d: table says %d, Elo says %d", d, got, want)
		}
	}
}

// The underdog gains more than the favourite, monotonically.
func TestTheUnderdogGainsMoreThanTheFavourite(t *testing.T) {
	r := rules()
	last := 1 << 30
	for edge := -400; edge <= 400; edge += 25 {
		m := Fight(r, 1500+edge, 1500, true)
		if m.DeltaA > last {
			t.Fatalf("edge %d gains %d, more than the smaller edge's %d", edge, m.DeltaA, last)
		}
		last = m.DeltaA
	}
}

// The DEFENDER moves half as far. This is the rule most likely to be
// "simplified" later into a symmetric swing, and a symmetric swing would mean a
// lord who never opens the app can be driven out of their league by strangers.
func TestADefenderMovesHalfAsFar(t *testing.T) {
	r := rules()
	for _, c := range []struct{ a, d int }{{1000, 1000}, {1200, 1000}, {1000, 1400}, {1800, 1100}} {
		for _, won := range []bool{true, false} {
			m := Fight(r, c.a, c.d, won)
			a, d := abs(m.DeltaA), abs(m.DeltaD)
			if half := a / 2; d < half-1 || d > half+1 {
				t.Fatalf("%d vs %d won=%v: attacker moved %d, defender %d (want about half)", c.a, c.d, won, a, d)
			}
			if (m.DeltaA > 0) == (m.DeltaD > 0) {
				t.Fatalf("%d vs %d won=%v: both moved the same way (%d, %d)", c.a, c.d, won, m.DeltaA, m.DeltaD)
			}
		}
	}
}

// No fight ever moves nothing. At a 700-point gap the favourite's share rounds
// the swing to zero, and a fight whose number did not move reads as broken.
func TestNoFightEverMovesNothing(t *testing.T) {
	r := rules()
	for a := 900; a <= 2400; a += 25 {
		for d := 900; d <= 2400; d += 25 {
			for _, won := range []bool{true, false} {
				m := Fight(r, a, d, won)
				if m.DeltaA == 0 || m.DeltaD == 0 {
					t.Fatalf("%d vs %d won=%v moved (%d, %d)", a, d, won, m.DeltaA, m.DeltaD)
				}
			}
		}
	}
}

// A rating never falls through the floor, and never climbs past the ceiling the
// column can hold.
func TestARatingStaysInsideItsColumn(t *testing.T) {
	r := rules()
	rating := r.Start
	for i := 0; i < 400; i++ {
		rating = Fight(r, rating, 2400, false).Attacker
	}
	if rating != r.Floor {
		t.Fatalf("four hundred losses left the rating at %d, not the floor %d", rating, r.Floor)
	}
	rating = 4990
	for i := 0; i < 50; i++ {
		rating = Fight(r, rating, 800, true).Attacker
	}
	if rating != r.Ceiling {
		t.Fatalf("fifty wins left the rating at %d, past the ceiling %d", rating, r.Ceiling)
	}
}

// The top league is a rating AND a place. Written as "or" it would be every
// lord above 1800, which at the end of a season is most of the ladder.
func TestTheTopLeagueNeedsARatingAndAPlace(t *testing.T) {
	ls := tiers()
	for _, c := range []struct {
		rating, place int
		want          string
	}{
		{1900, 51, "sapphire"}, {1900, 50, "imperial"}, {1900, 1, "imperial"},
		{1799, 1, "sapphire"}, {1800, 0, "sapphire"}, {1150, 0, "silver"},
		{0, 0, "bronze"}, {900, 0, "bronze"}, {1449, 0, "gold"},
	} {
		if got := League(ls, c.rating, c.place).ID; got != c.want {
			t.Fatalf("rating %d at place %d is %q, want %q", c.rating, c.place, got, c.want)
		}
	}
}

func TestHalfResetMovesHalfWayBack(t *testing.T) {
	r := rules()
	for _, c := range []struct{ in, want int }{{1600, 1300}, {1000, 1000}, {800, 900}, {2400, 1700}} {
		if got := HalfReset(r, c.in); got != c.want {
			t.Fatalf("HalfReset(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

// A band that inverts matches nobody, and a matchmaker that matches nobody
// silently turns every fight into a hired champion's.
func TestTheBandWidensAndNeverInverts(t *testing.T) {
	last := 0
	for step := 0; step <= 3; step++ {
		lo, hi := Band(150, 100, step, 1000)
		if lo > hi {
			t.Fatalf("step %d: band %d..%d is inverted", step, lo, hi)
		}
		if hi-lo <= last {
			t.Fatalf("step %d: band %d wide, no wider than the last (%d)", step, hi-lo, last)
		}
		last = hi - lo
	}
	if lo, _ := Band(150, 100, 3, 100); lo != 0 {
		t.Fatalf("a band round a low rating starts at %d, not 0", lo)
	}
}

func TestMilestonesArePaidOnceEach(t *testing.T) {
	at := []int{1150, 1300, 1450, 1600}
	rungs, mask := MilestonesCrossed(1320, at, 0)
	if len(rungs) != 2 || rungs[0] != 0 || rungs[1] != 1 {
		t.Fatalf("1320 crossed %v, want the first two", rungs)
	}
	if again, _ := MilestonesCrossed(1320, at, mask); len(again) != 0 {
		t.Fatalf("the same rating paid %v a second time", again)
	}
	if cleared, _ := MilestonesCrossed(1320, at, 0); len(cleared) != 2 {
		t.Fatalf("a cleared mask paid %d, want 2", len(cleared))
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
