package service

import (
	"strings"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The kingdom's shared goal and the counter it reads have to be the same
// vocabulary.
//
// goalDeeds switches on a goal's kind to turn an action into progress, and a
// kind nothing switches on moves no bar at all -- a hall staring at nought for a
// day with no error anywhere. This is the flaw the quests already shipped once
// (quests_kinds_test.go); gameconfig keeps the list because it cannot import
// this package, and this reads the switch and holds the two together.
func TestTheGoalSwitchKnowsEveryKindTheBalanceMayName(t *testing.T) {
	src := serviceSource(t, "help.go")
	i := strings.Index(src, "func goalDeeds(")
	if i < 0 {
		t.Fatal("goalDeeds is gone from help.go")
	}
	body := src[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	for _, kind := range gameconfig.KnownGoalKinds {
		if !strings.Contains(body, `case "`+kind+`":`) {
			t.Errorf("the balance may ask a kingdom for %q and goalDeeds does not read it", kind)
		}
	}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		kind := strings.TrimSuffix(strings.TrimPrefix(line, `case "`), `":`)
		found := false
		for _, k := range gameconfig.KnownGoalKinds {
			if k == kind {
				found = true
			}
		}
		if !found {
			t.Errorf("goalDeeds reads %q and the balance may never name it", kind)
		}
	}
}

// And the balance's own list is the shipped document's.
func TestEveryGoalKindShippedIsOneTheGameCounts(t *testing.T) {
	cfg, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range cfg.Social.Goal.Kinds {
		found := false
		for _, known := range gameconfig.KnownGoalKinds {
			if known == k.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("social.json ships the goal %q, which nothing counts", k.ID)
		}
	}
}
