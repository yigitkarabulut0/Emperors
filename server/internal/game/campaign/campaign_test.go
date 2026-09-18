package campaign

import (
	"math/rand/v2"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t testing.TB) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// The circle the campaign's difficulty rests on.
//
// scripts/gen-balance.py works out each garrison's Might with a Python mirror of
// internal/game/army and writes it down. gameconfig.Validate recomputes it in Go
// from the same document. This closes the circle at the far end: the units this
// package actually sends into the battle must be worth that same number. If the
// three ever disagree, the ladder the whole campaign was cut to is fiction.
func TestEveryGarrisonIsWorthWhatItsStageSays(t *testing.T) {
	c := cfg(t)
	n := 0
	for ci := range c.Campaign.Chapters {
		ch := &c.Campaign.Chapters[ci]
		for si := range ch.Stages {
			st := &ch.Stages[si]
			if got := Might(c, st.Enemy); got != st.Might {
				t.Fatalf("%s stage %d: the units fight at %d Might and the document says %d",
					ch.ID, st.Stage, got, st.Might)
			}
			n++
		}
	}
	if n != len(c.Campaign.Chapters)*c.Campaign.StagesPerChapter {
		t.Fatalf("walked %d stages", n)
	}
}

// And the army that goes to war has to be the roster that was weighed: the same
// count, the same attack, and a captain who carries the horse.
func TestTheArmyIsTheRoster(t *testing.T) {
	c := cfg(t)
	st := c.Stage("vale", 6)
	if st == nil {
		t.Fatal("no vale stage 6")
	}
	units, a := Roster(c, st.Enemy), Army(c, st.Enemy)
	if len(units) != len(a.Units) {
		t.Fatalf("the roster has %d units and the army %d", len(units), len(a.Units))
	}
	var rosterAtk, armyAtk, armySpd int64
	for i := range units {
		rosterAtk += units[i].Attack
		armyAtk += a.Units[i].Attack
		armySpd += a.Units[i].Speed
	}
	if rosterAtk != armyAtk {
		t.Fatalf("the roster attacks for %d and the army for %d", rosterAtk, armyAtk)
	}
	if armySpd != st.Enemy.Speed {
		t.Fatalf("the army moves at %d and the captain's horse is worth %d", armySpd, st.Enemy.Speed)
	}
	if !a.Units[0].IsHero {
		t.Fatal("the captain is not the face of their own garrison")
	}
}

// The road is a road.
func TestTheRoadOpensOneMileAtATime(t *testing.T) {
	c := cfg(t)
	first := c.ChapterAt(0)
	second := c.ChapterAt(1)
	s := Stars{}
	if !Open(c, s, first.ID, 1) {
		t.Fatal("the first mile of the first chapter is shut")
	}
	if Open(c, s, first.ID, 2) {
		t.Fatal("the second mile opened before the first was walked")
	}
	if Open(c, s, second.ID, 1) {
		t.Fatal("the second chapter opened before the first was walked")
	}
	s[first.ID] = map[int]int{1: 1}
	if !Open(c, s, first.ID, 2) {
		t.Fatal("the second mile stayed shut after the first was cleared")
	}
	// Walk the whole chapter and the next one opens.
	for _, st := range first.Stages {
		s[first.ID][st.Stage] = 3
	}
	if !Open(c, s, second.ID, 1) {
		t.Fatal("the second chapter stayed shut after the first was walked to its end")
	}
	if Open(c, s, first.ID, len(first.Stages)+1) {
		t.Fatal("a stage past the end of the chapter is open")
	}
	if Open(c, s, "no-such-chapter", 1) {
		t.Fatal("a chapter that does not exist is open")
	}
}

func TestWhereALordStands(t *testing.T) {
	c := cfg(t)
	first := c.ChapterAt(0)
	id, stage := Where(c, Stars{})
	if id != first.ID || stage != 1 {
		t.Fatalf("a new lord stands at %s %d", id, stage)
	}
	s := Stars{first.ID: {1: 1, 2: 3}}
	if id, stage = Where(c, s); id != first.ID || stage != 3 {
		t.Fatalf("after two miles a lord stands at %s %d", id, stage)
	}
	// Everything walked: the last mile, so the map has somewhere to open.
	all := Stars{}
	for ci := range c.Campaign.Chapters {
		ch := &c.Campaign.Chapters[ci]
		all[ch.ID] = map[int]int{}
		for _, st := range ch.Stages {
			all[ch.ID][st.Stage] = 3
		}
	}
	last := c.ChapterAt(len(c.Campaign.Chapters) - 1)
	if id, stage = Where(c, all); id != last.ID || stage != len(last.Stages) {
		t.Fatalf("a lord who walked the whole road stands at %s %d", id, stage)
	}
	if all.Total() != len(c.Campaign.Chapters)*c.Campaign.StagesPerChapter*3 {
		t.Fatalf("the whole road is %d stars", all.Total())
	}
	if all.InChapter(first.ID) != c.Campaign.StagesPerChapter*3 {
		t.Fatalf("a chapter is %d stars", all.InChapter(first.ID))
	}
}

func TestStarsAreTheWinAndWhatIsLeftOfYou(t *testing.T) {
	c := cfg(t)
	cases := []struct {
		won  bool
		hpBP int64
		want int
	}{
		{false, 9000, 0},
		{true, 0, 1},
		{true, c.Campaign.Stars.TwoAtHPBP - 1, 1},
		{true, c.Campaign.Stars.TwoAtHPBP, 2},
		{true, c.Campaign.Stars.ThreeAtHPBP - 1, 2},
		{true, c.Campaign.Stars.ThreeAtHPBP, 3},
		{true, 10000, 3},
	}
	for _, tc := range cases {
		if got := StarsFor(c, tc.won, tc.hpBP); got != tc.want {
			t.Errorf("won=%v hp=%d bp: %d stars, want %d", tc.won, tc.hpBP, got, tc.want)
		}
	}
}

// A repeat must never beat working. The rule is in the balance and Validate
// refuses a document that breaks it; here it is in the arithmetic a player is
// actually paid by.
func TestARepeatNeverBeatsWorking(t *testing.T) {
	c := cfg(t)
	for ci := range c.Campaign.Chapters {
		ch := &c.Campaign.Chapters[ci]
		for si := range ch.Stages {
			st := &ch.Stages[si]
			first := Reward(c, st, true)
			again := Reward(c, st, false)
			if again.GoldWages >= st.Energy {
				t.Fatalf("%s stage %d: a repeat pays %d wages for %d energy -- farming it beats working",
					ch.ID, st.Stage, again.GoldWages, st.Energy)
			}
			if first.GoldWages != st.Energy*c.Campaign.FirstClearWagesMult {
				t.Fatalf("%s stage %d: the first clear pays %d and should pay %d",
					ch.ID, st.Stage, first.GoldWages, st.Energy*c.Campaign.FirstClearWagesMult)
			}
			if st.IsBoss() {
				if len(first.Items) != 1 || first.Items[0].Tier != st.FirstClearItemTier {
					t.Fatalf("%s stage %d: a boss pays no gear the first time it falls", ch.ID, st.Stage)
				}
				if len(again.Items) != 0 {
					t.Fatalf("%s stage %d: a boss pays gear every time it falls", ch.ID, st.Stage)
				}
			}
		}
	}
}

func TestChestsOpenWithStars(t *testing.T) {
	c := cfg(t)
	ch := c.ChapterAt(0)
	if got := ChestsOpen(ch, 0); len(got) != 0 {
		t.Fatalf("a lord with no stars has %d chests", len(got))
	}
	if got := ChestsOpen(ch, ch.Chests[0].Stars); len(got) != 1 || got[0] != 0 {
		t.Fatalf("the first chest did not open at %d stars: %v", ch.Chests[0].Stars, got)
	}
	if got := ChestsOpen(ch, ch.StarsForChapter()); len(got) != len(ch.Chests) {
		t.Fatalf("a full chapter opened %d of %d chests", len(got), len(ch.Chests))
	}
}

// The stage ladder was cut by inverting combat's own win curve, so a lord who
// brings what the stage was written for must win most of the time -- and a
// boss, written at parity, must be a genuine wall.
func TestTheFirstChapterPlaysTheWayItWasWritten(t *testing.T) {
	c := cfg(t)
	ch := c.ChapterAt(0)
	for _, st := range []int{1, 6} {
		stage := c.Stage(ch.ID, st)
		mine := mirrorOf(c, stage.Enemy, stage.Might*int64(ratioBP(c, st))/10000)
		wins := 0
		const runs = 300
		for seed := uint64(1); seed <= runs; seed++ {
			rep := Battle(c, rand.New(rand.NewPCG(seed, 5)), seed, mine,
				army.Sum(toUnits(c, mine)).Might, stage.Enemy)
			if rep.Winner == combat.SideAttacker {
				wins++
			}
		}
		pct := wins * 100 / runs
		if st == 1 && (pct < 70 || pct > 95) {
			t.Errorf("the first mile is won %d%% of the time by a lord it was written for", pct)
		}
		if st == 6 && (pct < 35 || pct > 70) {
			t.Errorf("the chapter's boss is won %d%% of the time by a lord it was written for", pct)
		}
	}
}

// ratioBP is the Might advantage the stage was cut to give a lord of its level:
// the field stages open at 1.35 and the chapter's boss stands at parity.
func ratioBP(c *gameconfig.Bundle, stage int) int {
	if stage == 6 {
		return 10000
	}
	return 13500
}

// mirrorOf builds a lord's army worth `might` out of the garrison it fights, so
// the fight is measured on the ratio and nothing else.
func mirrorOf(c *gameconfig.Bundle, e gameconfig.Enemy, might int64) combat.Army {
	scaled := e
	base := Might(c, e)
	if base <= 0 {
		return combat.Army{}
	}
	bp := might * 10000 / base
	scaled.Attack = e.Attack * bp / 10000
	scaled.Defense = e.Defense * bp / 10000
	scaled.HP = e.HP * bp / 10000
	scaled.Speed = e.Speed * bp / 10000
	for i := range scaled.Soldiers {
		scaled.Soldiers[i].Count = e.Soldiers[i].Count
	}
	a := Army(c, scaled)
	a.PlayerID, a.Name = "lord", "A Lord"
	return a
}

func toUnits(c *gameconfig.Bundle, a combat.Army) []army.Unit {
	var out []army.Unit
	for _, u := range a.Units {
		out = append(out, army.Unit{
			Attack: u.Attack, Defense: u.Defense, Speed: u.Speed, HP: u.HP,
			EHP: army.EffectiveHP(c, u.HP, u.Defense, a.Level),
		})
	}
	return out
}
