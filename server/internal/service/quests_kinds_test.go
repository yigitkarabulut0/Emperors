package service

import (
	"strings"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The day's pool and the counter it reads have to be the same vocabulary.
//
// questProgress switches on a task's kind to pick a column off the day's row,
// and a kind nothing switches on falls through to zero -- a task that sits at
// nought all day with no error anywhere. gameconfig cannot import this package,
// so it keeps the list (KnownQuestKinds) and Validate refuses a pool that names
// anything else; this reads the switch and holds the two together.
func TestTheQuestSwitchKnowsEveryKindTheBalanceMayName(t *testing.T) {
	src := serviceSource(t, "quests.go")
	i := strings.Index(src, "func questProgress(")
	if i < 0 {
		t.Fatal("questProgress is gone from quests.go")
	}
	body := src[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	for _, kind := range gameconfig.KnownQuestKinds {
		if !strings.Contains(body, `case "`+kind+`":`) {
			t.Errorf("the balance may ask for %q and questProgress does not read it", kind)
		}
	}
	// And the other way: a case the balance has never heard of is a column
	// nothing can ever fill.
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		kind := strings.TrimSuffix(strings.TrimPrefix(line, `case "`), `":`)
		found := false
		for _, k := range gameconfig.KnownQuestKinds {
			if k == kind {
				found = true
			}
		}
		if !found {
			t.Errorf("questProgress reads %q and the balance may never name it", kind)
		}
	}
}
