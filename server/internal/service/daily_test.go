package service

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func dailyDeps(t *testing.T) Deps {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return Deps{Config: b}
}

func day(s string) pgtype.Date {
	d, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return pgtype.Date{Time: d, Valid: true}
}

// The page draws each square as the run stands: claimed behind today, today's
// square lit UNTIL IT IS TAKEN, the rest ahead -- and a broken run drawn as it
// would be mended, a lapsed one as a new start.
//
// Today's square used to stay "today" after it had been claimed, so a lord took
// their gift and the tile kept its waiting glow with no seal on it: the
// calendar never showed what they already had. A square a claim has been made
// on is a claimed square, whatever day it is.
func TestTheCalendarDrawsTheRun(t *testing.T) {
	d := dailyDeps(t)
	now := time.Date(2026, 3, 10, 9, 0, 0, 0, time.UTC)
	states := func(p sqlcdb.AppPlayer) (int, map[string]int) {
		st := d.calendarStatus(p, now)
		counts := map[string]int{}
		for _, s := range calendarSquares(d.Config, st, 10, economy.Bonuses{}) {
			counts[s.State]++
		}
		return st.Square, counts
	}
	cases := []struct {
		name   string
		p      sqlcdb.AppPlayer
		square int
		// Squares wearing the seal, and whether one is still lit and waiting.
		claimed int
		today   int
	}{
		{"a new lord", sqlcdb.AppPlayer{}, 1, 0, 1},
		{"claimed yesterday, day 6", sqlcdb.AppPlayer{CalendarPos: 6, DailyStreak: 6, DailyClaimedOn: day("2026-03-09")}, 7, 6, 1},
		// Seven sealed and nothing lit: the seventh was taken today.
		{"claimed today, day 7", sqlcdb.AppPlayer{CalendarPos: 7, DailyStreak: 7, DailyClaimedOn: day("2026-03-10")}, 7, 7, 0},
		{"after the 28th", sqlcdb.AppPlayer{CalendarPos: 28, DailyStreak: 28, DailyClaimedOn: day("2026-03-09")}, 1, 0, 1},
		{"broken, mendable", sqlcdb.AppPlayer{CalendarPos: 12, DailyStreak: 12, DailyClaimedOn: day("2026-03-08")}, 13, 12, 1},
		{"lapsed", sqlcdb.AppPlayer{CalendarPos: 12, DailyStreak: 12, DailyClaimedOn: day("2026-03-01")}, 1, 0, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sq, counts := states(c.p)
			if sq != c.square || counts[squareClaimed] != c.claimed || counts[squareToday] != c.today ||
				counts[squareClaimed]+counts[squareToday]+counts[squareAhead] != 28 {
				t.Fatalf("square %d, states %v; want square %d with %d sealed and %d lit",
					sq, counts, c.square, c.claimed, c.today)
			}
		})
	}
}

// A crown square's plate shows what the crown is for, not its diamonds; every
// other square shows its one reward.
func TestACrownShowsItsPrize(t *testing.T) {
	d := dailyDeps(t)
	sq := calendarSquares(d.Config, d.calendarStatus(sqlcdb.AppPlayer{}, time.Now()), 10, economy.Bonuses{})
	for _, s := range sq {
		if len(s.Lines) == 0 || s.Text == "" || s.Icon == "" {
			t.Fatalf("day %d says nothing: %+v", s.Day, s)
		}
		if s.Crown && s.Icon == "diamond" {
			t.Fatalf("crown day %d shows its diamonds, not its prize: %+v", s.Day, s)
		}
	}
	if !sq[27].Crown || sq[27].Lines[0].Amount != 100 {
		t.Fatalf("day 28 is the crown with 100 diamonds: %+v", sq[27])
	}
}

// A reward that turns over at UTC midnight turns over in the middle of the
// afternoon for a third of the world, which is why the offset is captured from
// the device at signup.
func TestDailyResetFollowsThePlayersOwnMidnight(t *testing.T) {
	d := dailyDeps(t)
	// 22:00 UTC. Already tomorrow in Istanbul (+3), still today in London.
	now := time.Date(2026, 3, 10, 22, 0, 0, 0, time.UTC)

	istanbul := sqlcdb.AppPlayer{
		CalendarPos: 1, DailyStreak: 1, DailyClaimedOn: day("2026-03-10"), ResetOffsetMinutes: 180,
	}
	if !d.calendarStatus(istanbul, now).Claimable {
		t.Error("it is already the 11th in Istanbul; the square should be available")
	}

	london := sqlcdb.AppPlayer{
		CalendarPos: 1, DailyStreak: 1, DailyClaimedOn: day("2026-03-10"), ResetOffsetMinutes: 0,
	}
	if d.calendarStatus(london, now).Claimable {
		t.Error("it is still the 10th in London; today's square is already taken")
	}
}
