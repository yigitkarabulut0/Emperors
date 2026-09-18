package deeds

import (
	"os"
	"regexp"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// A week starts on Monday, wherever in the week the day falls.
func TestWeekStartIsMonday(t *testing.T) {
	monday := time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC) // a Monday
	for i := 0; i < 7; i++ {
		day := monday.AddDate(0, 0, i)
		if got := WeekStart(day); !got.Equal(monday) {
			t.Fatalf("%s (%s) starts its week on %s", day.Format("2006-01-02"), day.Weekday(), got.Format("2006-01-02"))
		}
	}
	if got := WeekStart(monday.AddDate(0, 0, 7)); got.Equal(monday) {
		t.Fatal("the next Monday started the same week")
	}
}

// One action writes a lifetime row, a local-week row and a UTC-week row per
// kind, and nothing for a zero.
func TestRowsCoverEveryScope(t *testing.T) {
	local := time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC) // Sunday, the player's day
	now := time.Date(2026, 9, 21, 1, 30, 0, 0, time.UTC)  // already Monday in UTC
	s, p, k, v := Rows(Deeds{Collects: 3, Energy: 12, Raids: 0}, local, now)
	if len(s) != 6 || len(p) != 6 || len(k) != 6 || len(v) != 6 {
		t.Fatalf("got %d rows, want 6 (two kinds x three scopes, the zero left out)", len(s))
	}
	weeks := map[string]int64{}
	for i := range s {
		weeks[s[i]] = p[i]
	}
	if weeks[ScopeLife] != 0 {
		t.Fatalf("the lifetime period is %d, want 0", weeks[ScopeLife])
	}
	if weeks[ScopeWeek] == weeks[ScopeUWeek] {
		t.Fatal("a Sunday-night local week and a Monday UTC week landed in the same period")
	}
	if weeks[ScopeWeek] != EpochDay(time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("local week period %d, want the Monday 2026-09-14", weeks[ScopeWeek])
	}
	if k[0] != "collects" || v[0] != 3 {
		t.Fatalf("rows are not sorted by kind: first is %s=%d", k[0], v[0])
	}
}

// A running season and festival each get their own rows, on their own periods.
func TestRowsCoverTheSeasonAndTheFestival(t *testing.T) {
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	s, p, _, _ := Rows(Deeds{RaidWins: 1}, day, day.Add(9*time.Hour),
		Period{ScopeSeason, 1}, Period{ScopeEvent, 42})
	got := map[string]int64{}
	for i := range s {
		got[s[i]] = p[i]
	}
	if len(s) != 5 || got[ScopeSeason] != 1 || got[ScopeEvent] != 42 {
		t.Fatalf("rows %v periods %v; want five scopes with the season 1 and the festival 42", s, p)
	}
	if got[ScopeUWeek] != UWeek(day.Add(9*time.Hour)) {
		t.Fatal("the UTC week's period is not UWeek's")
	}
}

// Every counted deed is in All, once: a deed added to the constants and not to
// the list could not be counted by the dev tools, nor listed by anything else.
func TestEveryDeedIsListed(t *testing.T) {
	src, err := os.ReadFile("deeds.go")
	if err != nil {
		t.Fatal(err)
	}
	consts := regexp.MustCompile(`(?m)^\s+\w+\s+Kind = "(\w+)"`).FindAllStringSubmatch(string(src), -1)
	if len(consts) != len(All) {
		t.Fatalf("%d deeds declared, %d listed in All", len(consts), len(All))
	}
	seen := map[Kind]bool{}
	for _, c := range consts {
		k := Kind(c[1])
		if !Known(k) || seen[k] {
			t.Fatalf("%q is not listed once in All", k)
		}
		seen[k] = true
	}
}

// The balance names deeds too (a weekly task's, a guide step's), and gameconfig
// cannot import this package, so it keeps its own list: this holds the two
// together, or a task could count a deed nothing counts.
func TestTheBalanceKnowsEveryDeed(t *testing.T) {
	if len(gameconfig.KnownDeeds) != len(All) {
		t.Fatalf("gameconfig knows %d deeds, the game counts %d", len(gameconfig.KnownDeeds), len(All))
	}
	for i, k := range All {
		if gameconfig.KnownDeeds[i] != string(k) {
			t.Fatalf("deed %d is %q in the game and %q in gameconfig", i, k, gameconfig.KnownDeeds[i])
		}
	}
}
