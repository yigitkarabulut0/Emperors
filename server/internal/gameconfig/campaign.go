package gameconfig

// The Conquest Campaign (balance/campaign.json, Wave 7).
//
// Ten chapters of twelve stages fought against the realm's own garrisons, from
// level 6 -- four levels before another lord may raid back. It is where a lord
// learns what a battle is, and where a quiet evening's energy goes.
//
// A garrison is WRITTEN DOWN, not rolled: a captain and the soldiers behind
// them, with the Might of that roster recorded beside it. The generator works
// that Might out with a mirror of internal/game/army, and validate_campaign.go
// recomputes it here -- so a document whose recorded Might is not what the game
// would work out never reaches a player. tiers.json's stat_mult once drifted
// into fiction because nothing read it; this is the same mistake refused.

// CampaignConfig is the whole campaign.
type CampaignConfig struct {
	// The progression.sections gate. The level lives there and only there.
	Section string `json:"section"`

	StagesPerChapter int   `json:"stages_per_chapter"`
	BossStages       []int `json:"boss_stages"`

	Stars CampaignStars `json:"stars"`

	// What a clear pays, as multiples of the stage's energy in WAGES: three
	// times on the first clear, a fifth of that on a repeat.
	FirstClearWagesMult int64 `json:"first_clear_wages_mult"`
	RepeatBP            int64 `json:"repeat_bp"`

	Chapters []Chapter `json:"chapters"`
}

// CampaignStars is what a clear is worth: the win, and what is left of the hero.
type CampaignStars struct {
	Win         int   `json:"win"`
	TwoAtHPBP   int64 `json:"two_at_hp_bp"`
	ThreeAtHPBP int64 `json:"three_at_hp_bp"`
}

// Chapter is one map (art/reference/campaign_map_NN.png) and its twelve stages.
type Chapter struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Art   string `json:"art"`
	// The level its first stage is written for: what the map says before a lord
	// walks onto it.
	Level int64 `json:"level"`
	// The rank of gear its bosses pay the first time they fall.
	BossItemTier string `json:"boss_item_tier"`

	Chests []ChapterChest `json:"chests"`
	Stages []Stage        `json:"stages"`
}

// ChapterChest is one of the three a chapter's stars open.
type ChapterChest struct {
	Stars int          `json:"stars"`
	Grant RewardBundle `json:"grant"`
}

// Stage is one mile of the road.
type Stage struct {
	Stage int    `json:"stage"`
	Kind  string `json:"kind"` // field | boss
	Level int64  `json:"level"`
	// What it costs to walk it: 6 + ceil(s/10) of energy.
	Energy int64 `json:"energy"`
	// The garrison's Might, recorded here and checked against Go's own
	// arithmetic at publish time.
	Might int64 `json:"might"`
	Enemy Enemy `json:"enemy"`
	// A boss pays a piece of gear the first time it falls, and nothing the
	// times after: what brings a lord back is the stars.
	FirstClearItemTier string `json:"first_clear_item_tier,omitempty"`
}

// Enemy is a garrison: a captain, what they carry, and who stands with them.
type Enemy struct {
	Name  string `json:"name"`
	Level int64  `json:"level"`
	// The captain's own numbers, already resolved -- this is what the battle
	// fights, and what the recorded Might is computed from.
	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	HP      int64 `json:"hp"`
	// The captain's speed, off their horse, exactly as a lord's comes off
	// theirs. It is no part of Might -- Might is attack against effective hit
	// points -- but crit and dodge turn on it, and a garrison written down
	// without it would hand every player a quarter more damage and a free dodge
	// in seven while the stage still claimed to be an even fight.
	Speed    int64          `json:"speed"`
	Gear     *EnemyGear     `json:"gear,omitempty"`
	Soldiers []EnemySoldier `json:"soldiers"`
}

// EnemyGear says where a captain's numbers came from. Nothing reads it in a
// fight; it is there so the document explains itself and the screen can say
// what the captain carries.
type EnemyGear struct {
	Tier string `json:"tier"`
	ILvl int64  `json:"ilvl"`
}

// EnemySoldier is a rank of the garrison: a type, a tier and how many.
type EnemySoldier struct {
	Type  string `json:"type"`
	Tier  string `json:"tier"`
	Count int    `json:"count"`
}

// IsBoss reports a stage the chapter puts a wall at.
func (s Stage) IsBoss() bool { return s.Kind == "boss" }

// Chapter returns a chapter by id.
func (b *Bundle) Chapter(id string) *Chapter {
	for i := range b.Campaign.Chapters {
		if b.Campaign.Chapters[i].ID == id {
			return &b.Campaign.Chapters[i]
		}
	}
	return nil
}

// Stage returns one stage of one chapter, or nil.
func (b *Bundle) Stage(chapterID string, stage int) *Stage {
	c := b.Chapter(chapterID)
	if c == nil {
		return nil
	}
	for i := range c.Stages {
		if c.Stages[i].Stage == stage {
			return &c.Stages[i]
		}
	}
	return nil
}

// ChapterAt returns the nth chapter (0-based), or nil.
func (b *Bundle) ChapterAt(i int) *Chapter {
	if i < 0 || i >= len(b.Campaign.Chapters) {
		return nil
	}
	return &b.Campaign.Chapters[i]
}

// StarsForChapter is every star a chapter holds: three a stage.
func (c *Chapter) StarsForChapter() int { return len(c.Stages) * 3 }
