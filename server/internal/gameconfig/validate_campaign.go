package gameconfig

import "fmt"

// What the campaign, the hunt, the forge and the talents must be true of before
// they reach a player (Wave 7).
//
// The load-bearing one is the MIGHT. Every garrison in campaign.json carries the
// Might of its own roster, worked out by a mirror of internal/game/army in
// scripts/gen-balance.py. Here it is worked out again, in Go, from the same
// numbers the game fights with -- and a document whose recorded Might is not
// what the game would say is refused.
//
// That is not a formality. tiers.json's stat_mult drifted to a completely
// different curve from the multiplier the game ran on, and nothing caught it
// because nothing read it. A recorded number that nothing checks is a number
// that will eventually lie.

// campaignGearBand is how far a captain's gear may sit from their own level.
// gen-balance searches `level-4 .. level+4` and nothing else, so a mark outside
// it is a number that did not come from the stats written beside it.
const campaignGearBand = 4

func (b *Bundle) validateCampaign() []string {
	var p []string
	c := b.Campaign
	where := "campaign"

	if c.Section == "" || !b.HasSection(c.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if c.StagesPerChapter < 4 || c.StagesPerChapter > 40 {
		p = append(p, fmt.Sprintf("%s.stages_per_chapter is %d, outside 4..40", where, c.StagesPerChapter))
	}
	if len(c.BossStages) == 0 {
		p = append(p, where+".boss_stages is empty: a chapter with no wall in it is a corridor")
	}
	for _, s := range c.BossStages {
		if s < 1 || s > c.StagesPerChapter {
			p = append(p, fmt.Sprintf("%s.boss_stages has %d, which is not a stage", where, s))
		}
	}
	if c.Stars.Win < 1 {
		p = append(p, where+".stars.win is under one: a clear must be worth a star")
	}
	if c.Stars.TwoAtHPBP <= 0 || c.Stars.ThreeAtHPBP <= c.Stars.TwoAtHPBP || c.Stars.ThreeAtHPBP > 9000 {
		p = append(p, fmt.Sprintf("%s.stars: two at %d bp and three at %d bp of health left must rise, "+
			"and three must be reachable", where, c.Stars.TwoAtHPBP, c.Stars.ThreeAtHPBP))
	}
	if c.FirstClearWagesMult < 1 || c.FirstClearWagesMult > 10 {
		p = append(p, fmt.Sprintf("%s.first_clear_wages_mult is %d, outside 1..10", where, c.FirstClearWagesMult))
	}
	if c.RepeatBP <= 0 || c.RepeatBP >= 10000 {
		p = append(p, fmt.Sprintf("%s.repeat_bp is %d: a repeat pays a SHARE of the first clear", where, c.RepeatBP))
	}
	// The rule the whole wave rests on: fighting the same stage again must
	// never beat simply working. A repeat pays first_clear_mult * repeat_bp of
	// the stage's energy in wages, and wages are measured against the best job
	// -- so the product has to stay under one.
	if got := c.FirstClearWagesMult * c.RepeatBP; got >= 10000 {
		p = append(p, fmt.Sprintf("%s: a repeat pays %.2fx what the same energy collects "+
			"(%d x %d bp): farming a stage would beat working", where,
			float64(got)/10000, c.FirstClearWagesMult, c.RepeatBP))
	}
	if len(c.Chapters) == 0 {
		p = append(p, where+" has no chapters")
		return p
	}

	for ci := range c.Chapters {
		ch := &c.Chapters[ci]
		cw := fmt.Sprintf("%s.chapters[%s]", where, ch.ID)
		if ch.ID == "" || ch.Name == "" || ch.Art == "" {
			p = append(p, cw+" needs an id, a name and its own map")
		}
		if b.Items.TierMultBP[ch.BossItemTier] == 0 {
			p = append(p, fmt.Sprintf("%s.boss_item_tier %q is not a tier", cw, ch.BossItemTier))
		}
		if len(ch.Stages) != c.StagesPerChapter {
			p = append(p, fmt.Sprintf("%s has %d stages, and the campaign says %d",
				cw, len(ch.Stages), c.StagesPerChapter))
		}
		// The chests: their stars must rise, none may ask for more than the
		// chapter holds, and each must pay something a reward may carry.
		last := 0
		for i, chest := range ch.Chests {
			if chest.Stars <= last {
				p = append(p, fmt.Sprintf("%s.chests[%d] asks for %d stars, after %d: they must rise",
					cw, i, chest.Stars, last))
			}
			last = chest.Stars
			if chest.Stars > ch.StarsForChapter() {
				p = append(p, fmt.Sprintf("%s.chests[%d] asks for %d stars and the chapter holds %d",
					cw, i, chest.Stars, ch.StarsForChapter()))
			}
			if chest.Grant.Empty() {
				p = append(p, fmt.Sprintf("%s.chests[%d] pays nothing", cw, i))
			}
			// A campaign chest is free content: money buys nothing here, and
			// CheckReward is the one place that rule lives.
			for _, bad := range b.CheckReward(chest.Grant, false) {
				p = append(p, fmt.Sprintf("%s.chests[%d]: %s", cw, i, bad))
			}
		}

		prevLevel := int64(0)
		for si := range ch.Stages {
			s := &ch.Stages[si]
			sw := fmt.Sprintf("%s.stages[%d]", cw, s.Stage)
			if s.Stage != si+1 {
				p = append(p, fmt.Sprintf("%s is out of order (it is the %dth)", sw, si+1))
			}
			if s.Kind != "field" && s.Kind != "boss" {
				p = append(p, fmt.Sprintf("%s.kind is %q, not field or boss", sw, s.Kind))
			}
			if s.Level < prevLevel {
				p = append(p, fmt.Sprintf("%s is written for level %d, after level %d: the road only climbs",
					sw, s.Level, prevLevel))
			}
			prevLevel = s.Level
			if s.Energy <= 0 {
				p = append(p, sw+".energy is zero: a stage that costs nothing is a stage worth farming")
			}
			if s.FirstClearItemTier != "" && b.Items.TierMultBP[s.FirstClearItemTier] == 0 {
				p = append(p, fmt.Sprintf("%s.first_clear_item_tier %q is not a tier", sw, s.FirstClearItemTier))
			}
			if s.IsBoss() && s.FirstClearItemTier == "" {
				p = append(p, sw+" is a boss and pays no piece of gear the first time it falls")
			}
			// The garrison itself.
			e := s.Enemy
			if e.Name == "" {
				p = append(p, sw+".enemy has no name: a wall with no name is not a fight")
			}
			if e.Level <= 0 || e.Attack <= 0 || e.HP <= 0 {
				p = append(p, fmt.Sprintf("%s.enemy is not a fighter (level %d, attack %d, hp %d)",
					sw, e.Level, e.Attack, e.HP))
			}
			// Speed is no part of Might, so nothing above would catch its
			// absence: an unhorsed captain dodges nothing and crits at the
			// floor while the player crits at the cap.
			if e.Speed <= 0 {
				p = append(p, sw+".enemy has no speed: the player would crit at the cap and dodge "+
					"one blow in seven for free, and the stage would be easier than the Might it "+
					"is written to")
			}
			if e.Gear == nil {
				p = append(p, sw+".enemy carries nothing: a captain's speed comes off their horse")
			} else {
				// The gear is what the captain's attack, defense, hp and speed
				// were WORKED OUT FROM (gen-balance's `_hero_stats_geared`),
				// and it is what the stage's screen says they carry. Nothing
				// reads it in a fight, which is exactly why it is checked: a
				// readable number beside a real one, with no tie, is how
				// `stat_mult` drifted a whole curve. The soldiers' ranks are
				// checked three lines below and this was not.
				if b.Items.TierMultBP[e.Gear.Tier] == 0 {
					p = append(p, fmt.Sprintf("%s.enemy carries %q gear, which is not a rank",
						sw, e.Gear.Tier))
				}
				// The generator only ever searches four marks either side of the
				// captain's level, so anything outside that band did not come
				// from the numbers beside it.
				if d := e.Gear.ILvl - e.Level; e.Gear.ILvl <= 0 || d > campaignGearBand || d < -campaignGearBand {
					p = append(p, fmt.Sprintf(
						"%s.enemy is level %d and carries mark %d gear: outside the %d the stats were worked out from",
						sw, e.Level, e.Gear.ILvl, campaignGearBand))
				}
			}
			for _, g := range e.Soldiers {
				if b.SoldierType(g.Type) == nil {
					p = append(p, fmt.Sprintf("%s.enemy has %q, which is not a kind of soldier", sw, g.Type))
				}
				if b.Items.TierMultBP[g.Tier] == 0 {
					p = append(p, fmt.Sprintf("%s.enemy has a %q soldier, which is not a rank", sw, g.Tier))
				}
				if g.Count <= 0 {
					p = append(p, sw+".enemy has a rank of no soldiers")
				}
			}
			// And the number this whole file exists to hold: the Might the
			// document claims, against the Might the game would work out.
			if want := b.GarrisonMight(e); want != s.Might {
				p = append(p, fmt.Sprintf("%s says its garrison is worth %d and the game works it out "+
					"at %d: a recorded number that nothing checks is a number that will lie",
					sw, s.Might, want))
			}
		}
	}
	return p
}

// GarrisonMight works out what a written-down garrison is worth, with the same
// arithmetic internal/game/army uses on a lord's own roster.
//
// It lives here rather than in game/army because Validate has to refuse a bad
// document at PUBLISH time and gameconfig cannot import the game packages --
// they import it. army_test.go holds the two to each other.
func (b *Bundle) GarrisonMight(e Enemy) int64 {
	c := b.Soldiers.Combat
	dr := func(defense int64) int64 {
		if defense <= 0 {
			return 0
		}
		k := c.DRLevelCoef*e.Level + c.DRBase
		bp := defense * 10000 / (defense + k)
		if bp > c.DRCapBP {
			return c.DRCapBP
		}
		return bp
	}
	ehp := func(hp, defense int64) int64 {
		rem := 10000 - dr(defense)
		if rem <= 0 {
			rem = 1
		}
		return hp * 10000 / rem
	}

	attack := e.Attack
	total := ehp(e.HP, e.Defense)
	for _, g := range e.Soldiers {
		t := b.SoldierType(g.Type)
		if t == nil {
			continue
		}
		tierBP := b.Items.TierMultBP[g.Tier]
		scale := func(v int64) int64 { return (v*tierBP + 5000) / 10000 }
		sa, sd, sh := scale(t.Attack), scale(t.Defense), scale(t.HP)
		raw := sh + sd*c.HPPerDefenseBP/10000
		hp := raw * (10000 + c.HPLevelBonusBP*e.Level) / 10000
		for i := 0; i < g.Count; i++ {
			attack += sa
			total += ehp(hp, sd)
		}
	}
	return 2 * isqrt(attack*total)
}

// isqrt is Newton's method, the same integer square root army.UnitMight uses:
// Might feeds matchmaking and a screen that says who is stronger, and a float
// could differ in its last bit between two machines.
func isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x, y := n, (n+1)/2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
