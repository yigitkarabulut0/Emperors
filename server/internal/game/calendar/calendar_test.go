package calendar

import (
	"errors"
	"testing"
	"time"
)

func d(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}

// Every way a lord's last claim can sit against today, and what the page shows.
func TestTheCalendarReadsEachGap(t *testing.T) {
	today := d("2026-09-15")
	cases := []struct {
		name string
		s    State
		want Status
	}{
		{"never claimed", State{}, Status{Square: 1, Claimable: true}},
		{"claimed today", State{Pos: 6, Streak: 6, ClaimedOn: today}, Status{Square: 6, ClaimedToday: true}},
		{"claimed yesterday", State{Pos: 6, Streak: 6, ClaimedOn: d("2026-09-14")}, Status{Square: 7, Claimable: true}},
		{"after the 28th, a new cycle", State{Pos: 28, Streak: 28, ClaimedOn: d("2026-09-14")}, Status{Square: 1, Claimable: true}},
		{"one day missed: broken", State{Pos: 9, Streak: 9, ClaimedOn: d("2026-09-13")},
			Status{Square: 10, Claimable: true, Broken: true, Missed: 1}},
		{"two days missed: still mendable", State{Pos: 9, Streak: 9, ClaimedOn: d("2026-09-12")},
			Status{Square: 10, Claimable: true, Broken: true, Missed: 2}},
		{"three missed: lapsed, anew", State{Pos: 9, Streak: 9, ClaimedOn: d("2026-09-11")},
			Status{Square: 1, Claimable: true, Lapsed: true}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Read(c.s, 2, today); got != c.want {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
		})
	}
}

// A claim takes the next square; the 28th finishes a cycle; the first square of
// the next cycle brings a pardon, and a run begun anew does not.
func TestClaimsWalkTheCycle(t *testing.T) {
	s := State{}
	day := d("2026-09-01")
	var begins int
	for i := 1; i <= 30; i++ {
		after, sq, b, err := Claim(s, 2, day, MendNone)
		if err != nil {
			t.Fatalf("day %d: %v", i, err)
		}
		want := (i-1)%28 + 1
		if sq != want || after.Pos != want || after.Streak != i {
			t.Fatalf("day %d took square %d (pos %d, streak %d), want square %d", i, sq, after.Pos, after.Streak, want)
		}
		if b {
			begins++
		}
		s = after
		day = day.AddDate(0, 0, 1)
	}
	if s.Cycle != 1 || begins != 2 {
		t.Fatalf("after 30 days: cycle %d, %d cycles begun; want 1 and 2", s.Cycle, begins)
	}
	if _, _, _, err := Claim(s, 2, day.AddDate(0, 0, -1), MendNone); !errors.Is(err, ErrClaimed) {
		t.Fatalf("a second claim the same day: %v", err)
	}
}

// A broken run is refused without a mend; mended it carries on from where it
// was; begun anew it starts at square 1 without a pardon.
func TestABrokenRunIsMendedOrBegunAnew(t *testing.T) {
	s := State{Pos: 12, Streak: 40, Cycle: 1, ClaimedOn: d("2026-09-13")}
	today := d("2026-09-15")
	if _, _, _, err := Claim(s, 2, today, MendNone); !errors.Is(err, ErrBroken) {
		t.Fatalf("an unmended broken run: %v", err)
	}
	after, sq, begins, err := Claim(s, 2, today, MendPardon)
	if err != nil || sq != 13 || after.Streak != 41 || begins {
		t.Fatalf("mended: square %d streak %d begins %v err %v", sq, after.Streak, begins, err)
	}
	after, sq, begins, err = Claim(s, 2, today, MendAnew)
	if err != nil || sq != 1 || after.Streak != 1 || after.Cycle != 1 || begins {
		t.Fatalf("anew: square %d streak %d cycle %d begins %v err %v", sq, after.Streak, after.Cycle, begins, err)
	}
	fine := State{Pos: 3, Streak: 3, ClaimedOn: d("2026-09-14")}
	if _, _, _, err := Claim(fine, 2, today, MendDiamonds); !errors.Is(err, ErrNoBreak) {
		t.Fatalf("paying to mend an unbroken run: %v", err)
	}
	lapsed := State{Pos: 20, Streak: 20, ClaimedOn: d("2026-09-01")}
	after, sq, _, err = Claim(lapsed, 2, today, MendNone)
	if err != nil || sq != 1 || after.Streak != 1 {
		t.Fatalf("lapsed: square %d streak %d err %v", sq, after.Streak, err)
	}
}
