// Package campaign is the pure half of the Conquest Campaign: which mile of the
// road a lord may walk, what standing in it is worth, and who stands in it.
//
// Pure like the rest of internal/game. Nothing here knows about a database, the
// clock or a request; the service writes what this works out.
package campaign

import (
	"math/rand/v2"
	"strconv"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Stars is what a lord has earned so far: chapter id -> stage -> stars.
//
// A plain map, because that is what the database hands back and what every
// question here is asked of. Zero stars means "never cleared": a stage with a
// star is a stage that was won.
type Stars map[string]map[int]int

// At is the stars on one stage.
func (s Stars) At(chapter string, stage int) int { return s[chapter][stage] }

// InChapter is every star a lord holds in one chapter.
func (s Stars) InChapter(chapter string) int {
	n := 0
	for _, v := range s[chapter] {
		n += v
	}
	return n
}

// Total is every star a lord holds.
func (s Stars) Total() int {
	n := 0
	for id := range s {
		n += s.InChapter(id)
	}
	return n
}

// Cleared reports a stage that has been won at least once.
func (s Stars) Cleared(chapter string, stage int) bool { return s.At(chapter, stage) > 0 }

// Open reports whether a lord may walk this mile.
//
// The road is a road: the first stage of the first chapter is open to anyone the
// section gate let in, every other stage waits on the one before it, and a
// chapter opens when the chapter before it has been walked to its end. Nothing
// here asks about level -- the campaign's level gate is the section's, checked
// once where sections are checked.
func Open(cfg *gameconfig.Bundle, s Stars, chapterID string, stage int) bool {
	ci := chapterIndex(cfg, chapterID)
	if ci < 0 {
		return false
	}
	ch := &cfg.Campaign.Chapters[ci]
	if stage < 1 || stage > len(ch.Stages) {
		return false
	}
	if stage > 1 {
		return s.Cleared(chapterID, stage-1)
	}
	if ci == 0 {
		return true
	}
	prev := &cfg.Campaign.Chapters[ci-1]
	return s.Cleared(prev.ID, len(prev.Stages))
}

// Where a lord stands: the first stage they have not cleared. It is what the map
// opens on and what the ATTACK tab's badge counts from.
func Where(cfg *gameconfig.Bundle, s Stars) (chapterID string, stage int) {
	for ci := range cfg.Campaign.Chapters {
		ch := &cfg.Campaign.Chapters[ci]
		for _, st := range ch.Stages {
			if !s.Cleared(ch.ID, st.Stage) {
				return ch.ID, st.Stage
			}
		}
	}
	// Every mile walked: the last one, so the map has somewhere to stand.
	last := cfg.ChapterAt(len(cfg.Campaign.Chapters) - 1)
	if last == nil || len(last.Stages) == 0 {
		return "", 0
	}
	return last.ID, last.Stages[len(last.Stages)-1].Stage
}

// StarsFor is what a fought stage was worth.
//
// The win is one star; what is left of the lord is the other two. A loss is
// worth nothing at all -- the stage stays shut and the energy is spent, which is
// what makes the road a road rather than a queue.
func StarsFor(cfg *gameconfig.Bundle, won bool, hpLeftBP int64) int {
	if !won {
		return 0
	}
	c := cfg.Campaign.Stars
	stars := c.Win
	if hpLeftBP >= c.TwoAtHPBP {
		stars = 2
	}
	if hpLeftBP >= c.ThreeAtHPBP {
		stars = 3
	}
	return stars
}

// Reward is what clearing a stage pays.
//
// Wages, always: what the stage's energy would have earned at the best job the
// lord can do. Three times it the first time the stage falls, a fifth of that
// every time after -- 0.6 of simply collecting, so a stage is never worth
// farming and the reason to come back is the stars. A boss pays a piece of gear
// the first time it falls and never again.
//
// It returns a RewardBundle rather than gold, because a reward is paid in
// exactly one place (service.grantBundle) and this is the thing that place
// takes.
func Reward(cfg *gameconfig.Bundle, st *gameconfig.Stage, firstClear bool) gameconfig.RewardBundle {
	c := cfg.Campaign
	wages := st.Energy * c.FirstClearWagesMult
	var b gameconfig.RewardBundle
	if !firstClear {
		wages = wages * c.RepeatBP / 10000
	}
	if wages < 1 {
		wages = 1
	}
	b.GoldWages, b.XPWages = wages, wages
	if firstClear && st.FirstClearItemTier != "" {
		b.Items = []gameconfig.ItemGrant{{Tier: st.FirstClearItemTier, Count: 1}}
	}
	return b
}

// ChestsOpen is which of a chapter's chests this many stars have opened.
// Indices into the chapter's own list, so a claim names one thing.
func ChestsOpen(ch *gameconfig.Chapter, stars int) []int {
	var out []int
	for i, c := range ch.Chests {
		if stars >= c.Stars {
			out = append(out, i)
		}
	}
	return out
}

// Roster is the garrison as units: the captain, and the soldiers behind them.
//
// The arithmetic is army's own -- a soldier's base off its type and rank, hit
// points off base and defence, effective hit points off the damage reduction --
// so the Might of what comes out is the Might written in the document. The
// generator computes that number with a Python mirror and gameconfig.Validate
// recomputes it in Go; campaign_test.go closes the circle by fighting the units
// this function actually builds.
func Roster(cfg *gameconfig.Bundle, e gameconfig.Enemy) []army.Unit {
	units := make([]army.Unit, 0, 1+len(e.Soldiers))
	units = append(units, army.Unit{
		ID: "captain", Name: e.Name, IsHero: true, Level: e.Level,
		Attack: e.Attack, Defense: e.Defense, Speed: e.Speed, HP: e.HP,
		EHP: army.EffectiveHP(cfg, e.HP, e.Defense, e.Level),
	})
	for gi, g := range e.Soldiers {
		atk, def, baseHP := army.SoldierBase(cfg, g.Type, g.Tier)
		hp := army.UnitHP(cfg, baseHP, def, e.Level)
		ehp := army.EffectiveHP(cfg, hp, def, e.Level)
		name := g.Type
		if t := cfg.SoldierType(g.Type); t != nil {
			name = t.Name
		}
		for i := 0; i < g.Count; i++ {
			units = append(units, army.Unit{
				ID:   soldierID(gi, i),
				Name: name, Type: g.Type, Tier: g.Tier, Level: e.Level,
				Attack: atk, Defense: def, HP: hp, EHP: ehp,
			})
		}
	}
	return units
}

// Might is what a garrison is worth, from the units that actually fight.
func Might(cfg *gameconfig.Bundle, e gameconfig.Enemy) int64 {
	return army.Sum(Roster(cfg, e)).Might
}

// Army is the side a lord fights on a stage.
func Army(cfg *gameconfig.Bundle, e gameconfig.Enemy) combat.Army {
	a := combat.Army{PlayerID: "garrison", Name: e.Name, Level: e.Level}
	for _, u := range Roster(cfg, e) {
		a.Units = append(a.Units, combat.Combatant{
			ID: u.ID, Name: u.Name, Tier: u.Tier, Type: u.Type, IsHero: u.IsHero,
			Attack: u.Attack, Defense: u.Defense, Speed: u.Speed, HP: u.HP,
		})
	}
	return a
}

// Battle is a lord's army against a written-down garrison.
//
// A stage is fought EXACTLY as a raid is, with no options turned: the ladder of
// garrisons was cut by inverting the win curve combat's calibration test
// measures, and that curve is measured on an ordinary fight. A stage that fought
// by different rules would be a stage whose difficulty is a guess.
func Battle(cfg *gameconfig.Bundle, rng *rand.Rand, seed uint64, mine combat.Army,
	myMight int64, e gameconfig.Enemy) *combat.Replay {

	rep := combat.SimulateWith(cfg, rng, seed, mine, Army(cfg, e), combat.Options{})
	rep.AttackerMight, rep.DefenderMight = myMight, Might(cfg, e)
	return rep
}

// chapterIndex is where a chapter stands on the road, or -1.
func chapterIndex(cfg *gameconfig.Bundle, id string) int {
	for i := range cfg.Campaign.Chapters {
		if cfg.Campaign.Chapters[i].ID == id {
			return i
		}
	}
	return -1
}

func soldierID(group, i int) string {
	return "g" + strconv.Itoa(group) + "-" + strconv.Itoa(i)
}
