package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func seedDeps(t *testing.T) Deps {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return Deps{Config: b, Now: func() time.Time { return time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC) }}
}

// A kingdom called "100% Loyal" is searched for its percent sign, not for every
// kingdom in the realm, and a backslash cannot open an escape of its own.
func TestLikePatternEscapesWhatLikeWouldRead(t *testing.T) {
	cases := map[string]string{
		"lion":      `%lion%`,
		"100%":      `%100\%%`,
		"a_b":       `%a\_b%`,
		`back\lash`: `%back\\lash%`,
	}
	for in, want := range cases {
		if got := likePattern(in); got != want {
			t.Errorf("likePattern(%q) = %q, want %q", in, got, want)
		}
	}
}

// The button a card shows is decided here, in one order. The order matters: a
// player waiting out a cooldown must not be shown JOIN on an open kingdom, and
// a request already sent must stay withdrawable after the kingdom fills.
func TestCardActionOrder(t *testing.T) {
	id := uuid.New()
	free := viewer{invited: map[uuid.UUID]bool{}, requested: map[uuid.UUID]bool{}}
	cases := []struct {
		name    string
		look    viewer
		policy  string
		members int
		want    string
	}{
		{"open with room", free, policyOpen, 3, "join"},
		{"by request with room", free, policyRequest, 3, "request"},
		{"full", free, policyOpen, 10, "full"},
		{"invited to a by-request kingdom", viewer{invited: map[uuid.UUID]bool{id: true}}, policyRequest, 3, "accept"},
		{"asked, then it filled", viewer{requested: map[uuid.UUID]bool{id: true}}, policyRequest, 10, "requested"},
		{"waiting out a cooldown", viewer{waiting: true}, policyOpen, 3, "cooldown"},
		{"already in a kingdom", viewer{inKingdom: true}, policyOpen, 3, ""},
	}
	for _, c := range cases {
		if got := cardAction(c.look, id, c.policy, c.members, 10); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestShortWaitRoundsUp(t *testing.T) {
	cases := map[time.Duration]string{
		30 * time.Second:             "1m",
		42 * time.Minute:             "42m",
		59*time.Minute + time.Second: "1h 00m",
		65 * time.Minute:             "1h 05m",
	}
	for in, want := range cases {
		if got := shortWait(in); got != want {
			t.Errorf("shortWait(%v) = %q, want %q", in, got, want)
		}
	}
}

// The cooldown runs from the moment the player left, and ends when it says.
func TestRejoinWait(t *testing.T) {
	d := seedDeps(t)
	now := d.Now()
	mins := time.Duration(d.Config.Kingdoms.RejoinCooldownMinutes) * time.Minute

	if w := d.rejoinWait(sqlcdb.AppPlayer{}); w != 0 {
		t.Errorf("a player who never left waits %v", w)
	}
	justLeft := now.Add(-time.Minute)
	if w := d.rejoinWait(sqlcdb.AppPlayer{KingdomLeftAt: &justLeft}); w != mins-time.Minute {
		t.Errorf("a player who left a minute ago waits %v, want %v", w, mins-time.Minute)
	}
	longAgo := now.Add(-mins - time.Second)
	if w := d.rejoinWait(sqlcdb.AppPlayer{KingdomLeftAt: &longAgo}); w != 0 {
		t.Errorf("a player whose cooldown ran out still waits %v", w)
	}

	err := d.cooldownError(42*time.Minute, false)
	if !errors.Is(err, ErrRejoinCooldown) || !strings.Contains(err.Error(), "42m") {
		t.Errorf("the refusal should match ErrRejoinCooldown and name the wait: %v", err)
	}
	if kings := d.cooldownError(42*time.Minute, true); !strings.Contains(kings.Error(), "that lord") {
		t.Errorf("a king accepting someone should be told about them, not himself: %v", kings)
	}
}

// Every check below returns before the database; Deps has no pool, so reaching
// it would be a nil dereference. Passing is the proof the rule comes first.
func TestKingdomRefusalsBeforeTheDatabase(t *testing.T) {
	d := seedDeps(t)
	ctx := context.Background()
	me := uuid.New()

	if _, err := d.SetRole(ctx, me, uuid.New(), "captain"); !errors.Is(err, ErrBadRole) {
		t.Errorf("an unknown rank: got %v, want ErrBadRole", err)
	}
	if _, err := d.SetRole(ctx, me, me, "king"); !errors.Is(err, ErrBadTarget) {
		t.Errorf("a king naming himself: got %v, want ErrBadTarget", err)
	}
	if _, err := d.Kick(ctx, me, me); !errors.Is(err, ErrBadTarget) {
		t.Errorf("a lord removing himself: got %v, want ErrBadTarget", err)
	}
	if _, err := d.Invite(ctx, me, me); !errors.Is(err, ErrBadTarget) {
		t.Errorf("a lord inviting himself: got %v, want ErrBadTarget", err)
	}
	if _, err := d.SetPolicy(ctx, me, "closed"); !errors.Is(err, ErrBadPolicy) {
		t.Errorf("an unknown policy: got %v, want ErrBadPolicy", err)
	}
	if list, err := d.SearchKingdoms(ctx, me, " a "); err != nil || len(list) != 0 {
		t.Errorf("a one-letter search should find nothing without asking: %v %v", list, err)
	}
}

// A bad name is a 400 with the rule in it, whether founding or renaming; it
// used to be a 500 on rename.
func TestKingdomNameErrorsAreTyped(t *testing.T) {
	for name, tag := range map[string]string{"ab": "LION", "Lion Banner": "L", "Líon": "LION"} {
		err := validKingdomName(name, tag)
		if !errors.Is(err, ErrBadKingdomName) {
			t.Errorf("%q [%s]: got %v, want ErrBadKingdomName", name, tag, err)
		}
	}
	if err := validKingdomName("Lion Banner", "LION"); err != nil {
		t.Errorf("a good name was refused: %v", err)
	}
}

// The Royal Court's seats are its per-level bonus times its level. One call
// site passed the level where the bonus belonged and showed half the seats.
func TestMemberCapCountsTheCourt(t *testing.T) {
	d := seedDeps(t)
	court := d.Config.KingdomUpgrade(courtUpgradeID)
	if court == nil {
		t.Fatal("the seed has no Royal Court")
	}
	base := d.Config.KingdomMemberCap(3, 0)
	if got := d.memberCap(3, 2); got != base+2*int(court.PerLevel) {
		t.Errorf("memberCap(3, court 2) = %d, want %d", got, base+2*int(court.PerLevel))
	}
}

// The panel a player with no kingdom sees must never carry a null list: the
// hall iterates every one of them.
func TestKingdomViewListsAreNeverNull(t *testing.T) {
	raw, err := json.Marshal(newKingdomView(seedDeps(t)))
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"members", "upgrades", "invites", "leaderboard", "recommended", "requests"} {
		if !strings.Contains(string(raw), `"`+key+`":[`) {
			t.Errorf("%s is not an empty array: %s", key, raw)
		}
	}
}
