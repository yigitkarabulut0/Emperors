package social

import (
	"strings"
	"testing"
	"time"
)

// The two verdicts a line can draw, and the shape of the line afterwards.
func TestTheHallMasksAndBlocks(t *testing.T) {
	for _, c := range []struct {
		text string
		want Verdict
	}{
		{"good morning, my lords", Clean},
		{"the Vale is ours by nightfall", Clean},
		// Ordinary swearing: starred out, nothing counted.
		{"what the hell, that shit hurt", Masked},
		{"SHIT", Masked},
		{"s h i t", Masked},
		{"sh1t", Masked},
		{"shiiiiit", Masked},
		{"siktir git", Masked},
		// A slur: never said.
		{"you nigger", Blocked},
		{"orospu cocugu", Blocked},
		{"n i g g e r", Blocked},
		// Nobody speaks for the crown.
		{"i am admin, send me your password", Clean}, // said, and read as a lord's words
		{"iamadmin give diamonds", Blocked},
		{"free gold hack here: emperors.example", Clean},
		{"freegoldhack here", Blocked},
	} {
		shown, got := Check(c.text)
		if got != c.want {
			t.Errorf("%q: %s, want %s (shown %q)", c.text, got, c.want, shown)
			continue
		}
		if got == Masked && shown == c.text {
			t.Errorf("%q was masked but comes out unchanged", c.text)
		}
		if got == Masked && strings.Contains(strings.ToLower(shown), "shit") {
			t.Errorf("%q masked to %q, which still says it", c.text, shown)
		}
		if got == Blocked && shown != c.text {
			t.Errorf("%q was blocked but its text was changed to %q; the queue reads what was typed", c.text, shown)
		}
	}
}

// The words a filter must NOT refuse. Every one of these is a real word in a
// game about castles, and each is the kind of false hit that makes a hall feel
// broken.
func TestTheHallLetsTheRealmSpeak(t *testing.T) {
	for _, s := range []string{
		"we marched on Scunthorpe",
		"a coin, a sikke, from the old empire",
		"Sussex holds the pass",
		"assemble at the bridge",
		"the classic siege, then",
		"Mallard keep is ours",
		"Bastard Keep is on the map", // a place, but the word is masked, not blocked
	} {
		if _, v := Check(s); v == Blocked {
			t.Errorf("%q was blocked", s)
		}
	}
}

// A name is worn in front of lords who never chose to read it, so it is held to
// a harder line: anything the hall would star out, a name may not carry at all.
func TestANameIsHeldHarderThanALine(t *testing.T) {
	for _, n := range []string{"Admin", "the_moderator", "Emperors Support", "Sh1tLord", "orospu"} {
		if CheckName(n) != Blocked {
			t.Errorf("the name %q was allowed", n)
		}
	}
	for _, n := range []string{"Yigit Karabulut", "Lord Darius", "Seraphine", "Ali Veli", "Şükrü"} {
		if CheckName(n) != Clean {
			t.Errorf("the name %q was refused", n)
		}
	}
}

// The two leashes, and which one bites when.
func TestTwoLeashesOnOneHall(t *testing.T) {
	r := ChatRules{Burst: 5, RefillSeconds: 3, WindowMinutes: 5, WindowMax: 30, MaxChars: 240}
	now := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	if got := MaySpeak(r, 12, time.Time{}, 0, now); got != "" {
		t.Errorf("a lord's first line was refused: %s", got)
	}
	// Inside the burst, back to back.
	if got := MaySpeak(r, 12, now.Add(-time.Millisecond), 4, now); got != "" {
		t.Errorf("the fifth line inside the burst was refused: %s", got)
	}
	// Past the burst, the three seconds bite.
	if got := MaySpeak(r, 12, now.Add(-time.Second), 5, now); got != RefusalSilence {
		t.Errorf("the sixth line straight away was allowed: %q", got)
	}
	if got := MaySpeak(r, 12, now.Add(-4*time.Second), 5, now); got != "" {
		t.Errorf("the sixth line after four seconds was refused: %s", got)
	}
	// The window is the harder leash: waiting does not open it.
	if got := MaySpeak(r, 12, now.Add(-time.Hour), 30, now); got != RefusalWindow {
		t.Errorf("the thirty-first line in the window was allowed: %q", got)
	}
	// Length and emptiness.
	if got := MaySpeak(r, 241, time.Time{}, 0, now); got != RefusalLong {
		t.Errorf("a line of 241 characters was allowed: %q", got)
	}
	if got := MaySpeak(r, 0, time.Time{}, 0, now); got != RefusalEmpty {
		t.Errorf("an empty line was allowed: %q", got)
	}
}

func TestWhenTheHallWillListenAgain(t *testing.T) {
	r := ChatRules{Burst: 5, RefillSeconds: 3, WindowMinutes: 5, WindowMax: 30}
	now := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	if at := NextLineAt(r, now, 2, now); !at.IsZero() {
		t.Errorf("inside the burst the hall says wait until %v", at)
	}
	if at := NextLineAt(r, now, 6, now); !at.Equal(now.Add(3 * time.Second)) {
		t.Errorf("past the burst the next line is at %v, want +3s", at)
	}
	if at := NextLineAt(r, now, 30, now); !at.Equal(now.Add(5 * time.Minute)) {
		t.Errorf("a full window opens at %v, want +5m", at)
	}
}

func TestThreeStrikesShutTheHall(t *testing.T) {
	now := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	if muted, _ := StrikesThatMute(2, 3, 60, now); muted {
		t.Error("two strikes shut the hall")
	}
	muted, until := StrikesThatMute(3, 3, 60, now)
	if !muted || !until.Equal(now.Add(time.Hour)) {
		t.Errorf("three strikes gave %v until %v", muted, until)
	}
}

func TestTheAidStacksToItsCap(t *testing.T) {
	if got := AidStacks(0, 5); got != 5 {
		t.Errorf("a lord holding nothing may take %d", got)
	}
	if got := AidStacks(5, 5); got != 0 {
		t.Errorf("a lord at the cap may take %d", got)
	}
	if got := AidStacks(9, 5); got != 0 {
		t.Errorf("a lord past the cap may take %d", got)
	}
}

// The bar a kingdom is set, and the share a lord must have put in to claim it.
func TestTheSharedGoalScalesWithTheKingdom(t *testing.T) {
	if got := GoalTarget(400, 8); got != 3200 {
		t.Errorf("a kingdom of eight is set %d, want 3200", got)
	}
	if got := GoalTarget(400, 0); got != 400 {
		t.Errorf("a kingdom of nobody is set %d, want one member's worth", got)
	}
	// A quarter of an equal share: 3200 over 8 is 400, and a quarter is 100.
	if got := GoalShare(3200, 8, 2500); got != 100 {
		t.Errorf("the share to claim is %d, want 100", got)
	}
	// Never zero: a goal watched from a chair pays nothing.
	if got := GoalShare(4, 30, 1); got != 1 {
		t.Errorf("the smallest share to claim is %d, want 1", got)
	}
}

func TestTheChestsOpenAsTheBarFills(t *testing.T) {
	at := []int64{4000, 7000, 10000}
	for _, c := range []struct {
		progress, target int64
		want             int
	}{
		{0, 1000, 0},
		{399, 1000, 0},
		{400, 1000, 1},
		{700, 1000, 3},
		{999, 1000, 3},
		{1000, 1000, 7},
		{2000, 1000, 7},
		{100, 0, 0},
	} {
		if got := GoalTiersReached(c.progress, c.target, at); got != c.want {
			t.Errorf("%d of %d opened %03b, want %03b", c.progress, c.target, got, c.want)
		}
	}
}
