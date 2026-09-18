package war

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t testing.TB) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t.UTC()
}

// The week: drawn on a Friday evening, fought from Saturday.
func TestTheWeekIsDrawnOnFridayAndFoughtFromSaturday(t *testing.T) {
	c := cfg(t)
	// 2026-09-18 is a Friday.
	for _, moment := range []string{
		"2026-09-18T20:00:00Z", // the draw itself
		"2026-09-19T09:00:00Z", // Saturday
		"2026-09-21T23:59:00Z", // Monday night
	} {
		w := WindowFor(c, at(moment))
		if w.Drawn.Weekday() != time.Friday || w.Drawn.Hour() != c.War.MatchHour {
			t.Fatalf("%s: drawn %v", moment, w.Drawn)
		}
		if w.From.Weekday() != time.Saturday || w.From.Hour() != 0 {
			t.Fatalf("%s: the fighting starts %v", moment, w.From)
		}
		if got := w.To.Sub(w.From); got != time.Duration(c.War.Days)*24*time.Hour {
			t.Fatalf("%s: the war runs %v", moment, got)
		}
	}
	// Thursday belongs to the week BEFORE, and no war is running in it.
	w := WindowFor(c, at("2026-09-17T12:00:00Z"))
	if w.Drawn.Day() != 11 {
		t.Fatalf("Thursday was drawn %v", w.Drawn)
	}
	if w.Live(at("2026-09-17T12:00:00Z")) {
		t.Fatal("a war is running on the Thursday between two of them")
	}
	if !w.Live(w.From) || !w.Live(w.To.Add(-time.Second)) || w.Live(w.To) {
		t.Fatal("the window does not hold its own edges")
	}
	// And the next draw is always ahead.
	now := at("2026-09-19T09:00:00Z")
	if n := NextDraw(c, now); !n.After(now) || n.Weekday() != time.Friday {
		t.Fatalf("the next draw is %v", n)
	}
}

func side(id string, might int64, members int) Side {
	return Side{ID: id, Might: might, Member: members}
}

// The draw: nearest neighbours, never further apart than the balance allows,
// never the same pair twice running, and a bye rather than a slaughter.
func TestTheDrawMatchesNeighboursAndNeverRepeats(t *testing.T) {
	c := cfg(t)
	// Four kingdoms close enough that any of them could fight any other: what
	// the draw does with them is its own choice, not the ratio's.
	sides := []Side{
		side("a", 100_000, 10), side("b", 95_000, 10),
		side("c", 90_000, 10), side("d", 85_000, 10),
	}
	pairs := Draw(c, sides, nil)
	if len(pairs) != 2 {
		t.Fatalf("four kingdoms made %d pairs: %+v", len(pairs), pairs)
	}
	if pairs[0].A != "a" || pairs[0].B != "b" || pairs[1].A != "c" || pairs[1].B != "d" {
		t.Fatalf("the draw matched %+v", pairs)
	}
	// Last week's pair is not drawn again while there is anyone else to fight.
	again := Draw(c, sides, map[string]string{"a": "b", "b": "a"})
	if again[0].A != "a" || again[0].B != "c" {
		t.Fatalf("a and b were matched twice running: %+v", again)
	}
	if again[1].A != "b" || again[1].B != "d" {
		t.Fatalf("the rest of the realm was left standing: %+v", again)
	}

	// But a realm where nobody else is close enough gets its rematch rather
	// than two byes: a war is better than no war.
	far := Draw(c, []Side{
		side("a", 100_000, 10), side("b", 95_000, 10), side("m", 20_000, 10),
	}, map[string]string{"a": "b", "b": "a"})
	if far[0].A != "a" || far[0].B != "b" {
		t.Fatalf("two kingdoms with nobody else to fight sat the week out: %+v", far)
	}
	// With nobody else to fight, a rematch beats a bye.
	two := Draw(c, []Side{side("a", 100_000, 10), side("b", 95_000, 10)},
		map[string]string{"a": "b", "b": "a"})
	if len(two) != 1 || two[0].Bye {
		t.Fatalf("two kingdoms that fought last week sat the week out: %+v", two)
	}
}

func TestTheDrawRefusesAnUnfairPairAndAKingdomOfNobody(t *testing.T) {
	c := cfg(t)
	// Twice as strong: further apart than the balance allows.
	pairs := Draw(c, []Side{side("giant", 200_000, 10), side("mouse", 50_000, 10)}, nil)
	if len(pairs) != 2 || !pairs[0].Bye || !pairs[1].Bye {
		t.Fatalf("a giant was matched with a mouse: %+v", pairs)
	}
	// A kingdom under the balance's floor is not drawn at all.
	small := Draw(c, []Side{side("a", 10_000, 1), side("b", 10_000, 1)}, nil)
	if len(small) != 0 {
		t.Fatalf("kingdoms of one were drawn: %+v", small)
	}
	if len(Draw(c, nil, nil)) != 0 {
		t.Fatal("an empty realm made a pair")
	}
}

// What a win is worth: the ratio, clamped, and a quarter for a routed lord.
func TestAWinIsWorthTheRatioAndNoMore(t *testing.T) {
	c := cfg(t)
	p := c.War.Points
	even := WinPoints(c, 1000, 1000, false)
	if even != p.WinBase {
		t.Fatalf("an even fight pays %d, not %d", even, p.WinBase)
	}
	up := WinPoints(c, 1000, 5000, false)
	down := WinPoints(c, 5000, 1000, false)
	if up <= even || down >= even {
		t.Fatalf("punching up pays %d and down %d, against %d even", up, down, even)
	}
	if up != p.WinBase*p.RatioMax/10000 || down != p.WinBase*p.RatioMin/10000 {
		t.Fatalf("the clamp does not hold: up %d, down %d", up, down)
	}
	routed := WinPoints(c, 1000, 1000, true)
	if routed != even*c.War.RoutBP/10000 {
		t.Fatalf("beating a routed lord pays %d, not a quarter of %d", routed, even)
	}
	if WinPoints(c, 0, 1000, false) <= 0 {
		t.Fatal("a lord worth nothing pays nothing at all")
	}
	// And the rule the war rests on: attacking beats sitting still.
	if down <= HeldPoints(c) || LossPoints(c) >= down {
		t.Fatalf("the worst win pays %d, a held defence %d and a loss %d",
			down, HeldPoints(c), LossPoints(c))
	}
}

func TestABannerlessLordIsRouted(t *testing.T) {
	c := cfg(t)
	if Routed(c, c.War.Banners-1) {
		t.Fatal("a lord with a banner left is routed")
	}
	if !Routed(c, c.War.Banners) {
		t.Fatal("a lord with no banners left is not routed")
	}
	if Winner(10, 10, "a", "b") != "" {
		t.Fatal("a draw has a winner")
	}
	if Winner(11, 10, "a", "b") != "a" || Winner(10, 11, "a", "b") != "b" {
		t.Fatal("the winner is not the side with the points")
	}
}
