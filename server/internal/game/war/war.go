// Package war is the pure half of the kingdom wars: when a war is drawn and
// when it runs, who is matched with whom, and what everything that happens in
// one is worth.
//
// Pure like the rest of internal/game: time arrives as a parameter, and nothing
// here knows about a database or a request.
package war

import (
	"sort"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Window is one war's week: when the pairs were drawn, and the stretch the
// fighting runs over.
type Window struct {
	Drawn time.Time
	From  time.Time
	To    time.Time
}

// Live reports a moment inside the fighting.
func (w Window) Live(at time.Time) bool {
	return !at.Before(w.From) && at.Before(w.To)
}

// WindowFor is the war week `at` falls in: the draw before it, and the days
// that follow.
//
// The draw is a weekday and an hour in UTC (Friday 20:00), and the war runs
// from the next midnight for the balance's days -- Saturday, Sunday, Monday.
// Everything is worked out from the moment handed in, so a test can stand
// anywhere in the week and a job can ask "is one running now" without a clock
// of its own.
func WindowFor(cfg *gameconfig.Bundle, at time.Time) Window {
	c := cfg.War
	at = at.UTC()
	// The most recent draw at or before `at`.
	day := time.Date(at.Year(), at.Month(), at.Day(), c.MatchHour, 0, 0, 0, time.UTC)
	back := (int(day.Weekday()) + 6 - c.MatchWeekday) % 7 // Monday is 0 in the balance
	drawn := day.AddDate(0, 0, -back)
	if drawn.After(at) {
		drawn = drawn.AddDate(0, 0, -7)
	}
	from := time.Date(drawn.Year(), drawn.Month(), drawn.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, 1)
	return Window{Drawn: drawn, From: from, To: from.AddDate(0, 0, c.Days)}
}

// NextDraw is when the pairs are drawn next, after `at`.
func NextDraw(cfg *gameconfig.Bundle, at time.Time) time.Time {
	w := WindowFor(cfg, at)
	if w.Drawn.After(at) {
		return w.Drawn
	}
	return w.Drawn.AddDate(0, 0, 7)
}

// Side is a kingdom as the draw weighs it: its id and what its best members are
// worth together.
type Side struct {
	ID     string
	Might  int64
	Member int
}

// Pair is two kingdoms matched for a week, or one with nobody to fight.
type Pair struct {
	A   string
	B   string
	Bye bool
}

// Draw matches the kingdoms for a week.
//
// Sorted by what they are worth and paired with their nearest neighbour, so the
// two closest in strength meet; a pair further apart than the balance allows is
// not made at all, and a kingdom left over sits the week out with a bye rather
// than being thrown at somebody twice its size. `last` is who each kingdom
// fought the week before: nobody fights the same kingdom twice running while
// there is anyone else to fight.
func Draw(cfg *gameconfig.Bundle, sides []Side, last map[string]string) []Pair {
	c := cfg.War
	ready := make([]Side, 0, len(sides))
	for _, s := range sides {
		if s.Member >= c.MinMembers && s.Might > 0 {
			ready = append(ready, s)
		}
	}
	sort.Slice(ready, func(i, j int) bool {
		if ready[i].Might != ready[j].Might {
			return ready[i].Might > ready[j].Might
		}
		return ready[i].ID < ready[j].ID
	})

	var out []Pair
	used := make(map[string]bool, len(ready))
	for i := range ready {
		a := ready[i]
		if used[a.ID] {
			continue
		}
		// The nearest kingdom below that may be fought: close enough in
		// strength, and not the one they fought last week.
		best := -1
		for j := i + 1; j < len(ready); j++ {
			b := ready[j]
			if used[b.ID] || !within(c, a.Might, b.Might) {
				continue
			}
			if last[a.ID] == b.ID && hasOther(c, ready, used, a, b) {
				continue
			}
			best = j
			break
		}
		used[a.ID] = true
		if best < 0 {
			out = append(out, Pair{A: a.ID, Bye: true})
			continue
		}
		used[ready[best].ID] = true
		out = append(out, Pair{A: a.ID, B: ready[best].ID})
	}
	return out
}

// within reports two kingdoms close enough in strength to be matched.
func within(c gameconfig.WarConfig, a, b int64) bool {
	if a <= 0 || b <= 0 {
		return false
	}
	hi, lo := a, b
	if lo > hi {
		hi, lo = lo, hi
	}
	return hi*10000 <= lo*c.MaxRatioBP
}

// hasOther reports another kingdom `a` could be matched with instead of `b`.
func hasOther(c gameconfig.WarConfig, ready []Side, used map[string]bool, a, b Side) bool {
	for _, s := range ready {
		if s.ID == a.ID || s.ID == b.ID || used[s.ID] {
			continue
		}
		if within(c, a.Might, s.Might) {
			return true
		}
	}
	return false
}

// WinPoints is what beating a lord is worth: the balance's base times the Might
// ratio, clamped, and a quarter of that when the lord had already lost every
// banner they had.
//
// Punching up is worth more and farming down is worth less, which is the whole
// reason the ratio is in it; the clamp is what stops one win on a giant from
// deciding the week.
func WinPoints(cfg *gameconfig.Bundle, mine, theirs int64, routed bool) int64 {
	p := cfg.War.Points
	ratio := p.RatioMax
	if mine > 0 {
		ratio = theirs * 10000 / mine
	}
	if ratio < p.RatioMin {
		ratio = p.RatioMin
	}
	if ratio > p.RatioMax {
		ratio = p.RatioMax
	}
	pts := p.WinBase * ratio / 10000
	if routed {
		pts = pts * cfg.War.RoutBP / 10000
	}
	if pts < 1 {
		pts = 1
	}
	return pts
}

// LossPoints is what turning up and losing is worth.
func LossPoints(cfg *gameconfig.Bundle) int64 { return cfg.War.Points.Loss }

// HeldPoints is what a defender's kingdom takes when they hold.
func HeldPoints(cfg *gameconfig.Bundle) int64 { return cfg.War.Points.Held }

// Routed reports a defender with no banners left: they may still be attacked,
// and beating them is worth a quarter.
func Routed(cfg *gameconfig.Bundle, bannersLost int) bool {
	return bannersLost >= cfg.War.Banners
}

// Winner is the side with the most points, or "" for a draw.
func Winner(a, b int64, aID, bID string) string {
	switch {
	case a > b:
		return aID
	case b > a:
		return bID
	}
	return ""
}
