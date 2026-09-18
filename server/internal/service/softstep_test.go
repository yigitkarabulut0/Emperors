package service

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Progress counters are written in one place, inside a savepoint.
//
// A counter that fails inside the action's own transaction aborts the whole
// transaction in Postgres, however carefully its error is swallowed: the COMMIT
// then comes back as a rollback and the collect, raid or purchase that earned
// the tick fails with a 500. softStep is the only thing that contains it, and
// recordDeeds is the only thing that writes counters, so a bare bumpQuests
// anywhere else is the old bug back.
func TestCountersAreWrittenInOnePlaceInASavepoint(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if strings.Contains(src, "logQuestBump") {
			t.Errorf("%s still swallows a quest bump in the outer transaction (logQuestBump)", f)
		}
		calls := strings.Count(src, "d.bumpQuests(")
		if f == "deeds.go" {
			if calls != 1 {
				t.Errorf("deeds.go calls bumpQuests %d times, want exactly once", calls)
			}
			if !strings.Contains(src, `d.softStep(ctx, tx, "deeds"`) {
				t.Error("recordDeeds no longer runs inside a savepoint")
			}
			continue
		}
		if calls > 0 {
			t.Errorf("%s calls bumpQuests directly; every action reports through recordDeeds", f)
		}
	}
}

// Every action that something counts reports through recordDeeds.
func TestEveryCountedActionRecordsItsDeeds(t *testing.T) {
	for file, fn := range map[string]string{
		"collect.go":       "func (d Deps) Collect(",
		"collect_batch.go": "func (d Deps) CollectBatch(",
		// Attack is a two-line wrapper on the shared raid path since Wave 5, and
		// the path is where the counting happens -- for the revenge strike and
		// the bounty hunt alike.
		"attack.go":          "func (d Deps) raid(",
		"arena.go":           "func (d Deps) ArenaFight(",
		"bounty.go":          "func (d Deps) PlaceBounty(",
		"shop.go":            "func (d Deps) Buy(",
		"inventory.go":       "func (d Deps) Sell(",
		"army.go":            "func (d Deps) Recruit(",
		"reroll.go":          "func (d Deps) RerollSoldier(",
		"estates.go":         "func (d Deps) buyLevel(",
		"kingdom_actions.go": "func (d Deps) Donate(",
		"stats.go":           "func (d Deps) SpendStats(",
		"quests.go":          "func (d Deps) ClaimQuest(",
		"daily.go":           "func (d Deps) ClaimDaily(",
		"mail.go":            "func (d Deps) ClaimMail(",
		// PvE ve derinlik (Wave 7).
		"campaign.go": "func (d Deps) FightStage(",
		"hunt.go":     "func (d Deps) SendHunt(",
		"forge.go":    "func (d Deps) Forge(",
	} {
		src := serviceSource(t, file)
		i := strings.Index(src, fn)
		if i < 0 {
			t.Errorf("%s: %s is gone", file, fn)
			continue
		}
		body := src[i:]
		if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
			body = body[:j+1]
		}
		if !strings.Contains(body, "d.recordDeeds(") {
			t.Errorf("%s: %s no longer records its deeds", file, fn)
		}
	}
}

// A single collect counts toward today's tasks, as a batch always did.
func TestASingleCollectCountsTowardQuests(t *testing.T) {
	src := serviceSource(t, "collect.go")
	i := strings.Index(src, "func (d Deps) Collect(")
	if i < 0 {
		t.Fatal("Collect is gone from collect.go")
	}
	if !strings.Contains(src[i:], "deeds.Collects: 1, deeds.Energy: job.EnergyCost") {
		t.Fatal("a single collect no longer counts toward today's tasks")
	}
}
