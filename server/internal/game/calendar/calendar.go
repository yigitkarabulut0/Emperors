// Package calendar is the 28-day login calendar's rules: which square a claim
// takes, when a run is broken and when it is lost, and what mending it costs.
//
// Pure: days arrive as arguments, as calendar dates at UTC midnight in the
// lord's own time zone (service.localDay).
package calendar

import (
	"errors"
	"time"
)

// Squares on the calendar.
const Squares = 28

// State is what the player row keeps.
type State struct {
	// Squares claimed in the current cycle, 0..28: the next claim takes Pos+1,
	// and after the 28th the next takes the first square of a new cycle.
	Pos int
	// Days claimed in a row, however many cycles that spans.
	Streak int
	// Cycles finished (the 28th square claimed).
	Cycle int
	// The local day of the last claim; zero for a lord who never claimed.
	ClaimedOn time.Time
}

// Mend is how a broken run is mended at a claim.
type Mend string

const (
	MendNone     Mend = ""
	MendDiamonds Mend = "diamonds"
	MendPardon   Mend = "pardon"
	MendAnew     Mend = "anew"
)

// Status is the calendar as it reads today.
type Status struct {
	// The square a claim takes today (1-28) -- or took, once claimed.
	Square int
	// Whether a claim can be made today, with a mend when Broken.
	Claimable    bool
	ClaimedToday bool
	// Broken: 1..grace days were missed. The run can be mended (Square is then
	// the square after the last one claimed) or begun anew (square 1).
	Broken bool
	Missed int
	// The last claim was so long ago the run is gone: today starts anew.
	Lapsed bool
}

var (
	ErrClaimed = errors.New("today's square is already claimed")
	ErrBroken  = errors.New("the run is broken: mend it or start anew")
	ErrNoBreak = errors.New("there is nothing to mend")
)

// DaysBetween is the whole days from a to b, both calendar dates.
func DaysBetween(a, b time.Time) int {
	return int(b.Sub(a).Hours()+0.5) / 24
}

// Read is the calendar as it stands on today.
func Read(s State, graceDays int, today time.Time) Status {
	if s.ClaimedOn.IsZero() {
		return Status{Square: 1, Claimable: true}
	}
	gap := DaysBetween(s.ClaimedOn, today)
	switch {
	case gap <= 0:
		sq := s.Pos
		if sq < 1 {
			sq = 1
		}
		return Status{Square: sq, ClaimedToday: true}
	case gap == 1:
		return Status{Square: next(s.Pos), Claimable: true}
	case gap-1 <= graceDays:
		return Status{Square: next(s.Pos), Claimable: true, Broken: true, Missed: gap - 1}
	default:
		return Status{Square: 1, Claimable: true, Lapsed: true}
	}
}

// next is the square after pos squares claimed: the 29th is a new cycle's first.
func next(pos int) int {
	if pos >= Squares {
		return 1
	}
	return pos + 1
}

// Claim takes today's square. It returns the state after, the square taken,
// and whether this claim begins a cycle (a pardon comes with it).
//
// A broken run needs a mend: MendDiamonds or MendPardon keep it (the caller
// takes the price or the pardon), MendAnew starts over at square 1. A lapsed
// run starts over by itself.
func Claim(s State, graceDays int, today time.Time, mend Mend) (State, int, bool, error) {
	st := Read(s, graceDays, today)
	if st.ClaimedToday {
		return s, 0, false, ErrClaimed
	}
	if st.Broken && mend == MendNone {
		return s, 0, false, ErrBroken
	}
	if !st.Broken && (mend == MendDiamonds || mend == MendPardon) {
		return s, 0, false, ErrNoBreak
	}

	after := State{ClaimedOn: today, Cycle: s.Cycle}
	fresh := s.ClaimedOn.IsZero() || st.Lapsed || mend == MendAnew
	var square int
	if fresh {
		square = 1
		after.Pos = 1
		after.Streak = 1
	} else {
		square = st.Square
		after.Pos = square
		after.Streak = s.Streak + 1
	}
	if square == Squares {
		after.Cycle++
	}
	// A cycle begins with a new lord's first square, or with the first square
	// after a finished 28th -- never with a run begun anew, so a pardon cannot be
	// had by breaking a run on purpose.
	begins := square == 1 && (s.ClaimedOn.IsZero() || (!fresh && s.Pos >= Squares))
	return after, square, begins, nil
}
