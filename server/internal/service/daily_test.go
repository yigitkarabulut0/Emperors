package service

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
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

// The calendar's whole value is that missing a day costs you the week. Every
// one of these cases is a different way a player's clock can relate to the
// stored one, and getting any of them wrong either pays twice or never.
func TestDailyStreakWalksTheCalendar(t *testing.T) {
	d := dailyDeps(t)
	now := time.Date(2026, 3, 10, 9, 0, 0, 0, time.UTC)
	week := len(d.Config.Progression.DailyLogin.Rewards)

	cases := []struct {
		name          string
		streak        int32
		claimedOn     pgtype.Date
		offsetMinutes int32
		wantDay       int
		wantClaimable bool
	}{
		{"never claimed", 0, pgtype.Date{}, 0, 1, true},
		{"claimed yesterday", 3, day("2026-03-09"), 0, 4, true},
		{"claimed today", 3, day("2026-03-10"), 0, 3, false},
		{"missed a day resets the week", 5, day("2026-03-08"), 0, 1, true},
		{"missed a month resets the week", 6, day("2026-02-01"), 0, 1, true},
		// The seventh square is the point of the whole thing; the eighth day
		// must come back round to the first.
		{"week wraps", int32(week), day("2026-03-09"), 0, 1, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := sqlcdb.AppPlayer{
				DailyStreak: c.streak, DailyClaimedOn: c.claimedOn,
				ResetOffsetMinutes: c.offsetMinutes,
			}
			gotDay, gotClaimable := d.dailyState(p, now)
			if gotDay != c.wantDay || gotClaimable != c.wantClaimable {
				t.Errorf("day=%d claimable=%v, want day=%d claimable=%v",
					gotDay, gotClaimable, c.wantDay, c.wantClaimable)
			}
		})
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
		DailyStreak: 1, DailyClaimedOn: day("2026-03-10"), ResetOffsetMinutes: 180,
	}
	if _, claimable := d.dailyState(istanbul, now); !claimable {
		t.Error("it is already the 11th in Istanbul; the square should be available")
	}

	london := sqlcdb.AppPlayer{
		DailyStreak: 1, DailyClaimedOn: day("2026-03-10"), ResetOffsetMinutes: 0,
	}
	if _, claimable := d.dailyState(london, now); claimable {
		t.Error("it is still the 10th in London; today's square is already taken")
	}
}
