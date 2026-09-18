package gameconfig

import "fmt"

// KnownQuestKinds is what a daily task may watch.
//
// The service switches on these names to read a counter off the day's row
// (service/quests.go, questProgress), and a name nothing switches on reads as
// no progress at all -- a task that can never be finished and no error
// anywhere. gameconfig cannot import the service, so the list lives here and
// quests_test.go in the service holds the switch to it.
var KnownQuestKinds = []string{
	"collects", "wins", "buys", "energy",
	// PvE ve derinlik (Wave 7).
	"stages", "hunts", "aids",
	// Krallik Boss ve Savaslari (Wave 8): a blow struck at the kingdom's beast.
	"blows",
}

func knownQuestKind(k string) bool {
	for _, x := range KnownQuestKinds {
		if x == k {
			return true
		}
	}
	return false
}

// validateQuests holds the day's pool to what the game can actually count.
func (b *Bundle) validateQuests() []string {
	var p []string
	c := b.Progression.Quests
	where := "progression.quests"

	if c.PerDay < 1 {
		p = append(p, where+".per_day is under one: a day with no task is not a day's tasks")
	}
	if c.XPPerLevelPerTier <= 0 || c.GoldPerLevelPerTier <= 0 {
		p = append(p, where+" pays nothing a tier, so every task is worth nothing")
	}
	if len(c.Pool) < c.PerDay {
		p = append(p, fmt.Sprintf("%s draws %d a day from a pool of %d", where, c.PerDay, len(c.Pool)))
	}
	seen := map[string]bool{}
	for _, q := range c.Pool {
		qw := fmt.Sprintf("%s[%s]", where, q.ID)
		if q.ID == "" || q.Name == "" || q.Blurb == "" {
			p = append(p, qw+" needs an id, a name and a line saying what it asks")
		}
		if seen[q.ID] {
			p = append(p, qw+" is in the pool twice")
		}
		seen[q.ID] = true
		if !knownQuestKind(q.Kind) {
			p = append(p, fmt.Sprintf("%s watches %q, which nothing counts: the task would sit at "+
				"zero all day and nothing would report an error", qw, q.Kind))
		}
		if q.Target < 1 {
			p = append(p, fmt.Sprintf("%s asks for %d", qw, q.Target))
		}
		if q.Tier < 1 {
			p = append(p, fmt.Sprintf("%s is tier %d, so it pays nothing", qw, q.Tier))
		}
		if q.MinLevel < 0 || q.MinLevel > b.Progression.LevelCap {
			p = append(p, fmt.Sprintf("%s opens at level %d", qw, q.MinLevel))
		}
		if q.Needs != "" && q.Needs != QuestNeedsKingdom {
			p = append(p, fmt.Sprintf("%s needs %q, which is not something a lord can have", qw, q.Needs))
		}
	}
	return p
}
