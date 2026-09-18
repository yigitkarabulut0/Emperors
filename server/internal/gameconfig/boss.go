package gameconfig

// The kingdom's boss (balance/boss.json, Wave 8).
//
// One beast stands against a kingdom for 48 hours. Every member may strike it
// six times, each blow costing the energy a raid costs, and a blow is a real
// fight cut to eight rounds: what the lord did to the beast in them is their
// damage. So a stronger army digs deeper, a lord who falls early digs less, and
// the client animates the same replay a raid animates.
//
// The beast's health is the KINGDOM'S own Might times a calibrated share, per
// blow the kingdom has. That is what makes it the same fight for five lords and
// for twenty: what changes is how many swords are raised, not whether the wall
// can be broken. The share is measured, not guessed --
// internal/game/boss/calibration_test.go fights a cycle of reference lords and
// holds the kill rate to the design's 65-80%.

// BossConfig is the whole raid.
type BossConfig struct {
	// The progression.sections gate. A boss is a KINGDOM's, so what really
	// opens it is having one; the section is here for the screen to say so.
	Section string `json:"section"`

	CycleHours     int   `json:"cycle_hours"`
	HitsPerMember  int   `json:"hits_per_member"`
	RoundsPerHit   int   `json:"rounds_per_hit"`
	EnergyBase     int64 `json:"energy_base"`
	EnergyPerLevel int64 `json:"energy_per_level_bp"`

	// The wall: Might x this, per blow the kingdom has, and a tenth more each
	// time the beast has been put down.
	HPPerMightBP int64 `json:"hp_per_might_bp"`
	HPGrowthBP   int64 `json:"hp_growth_bp"`
	MaxLevel     int   `json:"max_level"`

	// What a lord must do to be counted brave: this share of an equal share.
	ValourShareBP int64 `json:"valour_share_bp"`
	// What the first three on the damage list take, and what the first is called.
	TopDiamonds []int64 `json:"top_diamonds"`
	TopTitle    string  `json:"top_title"`

	Rotation []Boss      `json:"rotation"`
	Chests   []BossChest `json:"chests"`
	// What a chest is worth at the beast's level: a tenth more each time.
	ChestGrowthBP int64 `json:"chest_growth_bp"`
}

// Boss is one of the six that come round.
type Boss struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Art   string `json:"art"`
	// Its own numbers, as shares of the kingdom's Might: a beast that hits for
	// a share of what the kingdom is worth is a beast every kingdom meets the
	// same way.
	AttackBP  int64 `json:"attack_bp"`
	DefenseBP int64 `json:"defense_bp"`
}

// BossChest is one of the three under the beast. `Need` is what it asks for:
// "hit" (a blow landed), "valour" (a share of the damage) or "kill".
type BossChest struct {
	ID    string       `json:"id"`
	Name  string       `json:"name"`
	Need  string       `json:"need"`
	Grant RewardBundle `json:"grant"`
}

// The three things a chest may ask for.
const (
	BossNeedHit    = "hit"
	BossNeedValour = "valour"
	BossNeedKill   = "kill"
)

// GrowTo is what a written figure is worth at a beast's LEVEL: the balance's
// step, compounded once for every beast this kingdom has already put down.
//
// One implementation, because two questions have to ask it -- what the settle
// pays (internal/game/boss.Chest), and whether the hardest beast a kingdom can
// reach would still pay a letter the post office will carry (validateBoss).
func (b BossConfig) GrowTo(v int64, level int) int64 {
	for i := 1; i < level; i++ {
		v = v * b.ChestGrowthBP / 10000
	}
	return v
}

// GrownChest is one chest as it would be paid at a level.
func (b BossConfig) GrownChest(c *BossChest, level int) RewardBundle {
	if c == nil {
		return RewardBundle{}
	}
	g := c.Grant
	g.GoldWages, g.XPWages = b.GrowTo(g.GoldWages, level), b.GrowTo(g.XPWages, level)
	g.Gold, g.XP = b.GrowTo(g.Gold, level), b.GrowTo(g.XP, level)
	// Diamonds and tokens do NOT grow: a beast that paid a tenth more diamonds
	// every time would be a diamond mine with a dragon painted on it.
	return g
}

// BossAt returns the nth beast of the rotation (0-based, wrapping), or nil.
func (b BossConfig) BossAt(n int) *Boss {
	if len(b.Rotation) == 0 {
		return nil
	}
	i := n % len(b.Rotation)
	if i < 0 {
		i += len(b.Rotation)
	}
	return &b.Rotation[i]
}

// Boss returns one by id.
func (b BossConfig) Boss(id string) *Boss {
	for i := range b.Rotation {
		if b.Rotation[i].ID == id {
			return &b.Rotation[i]
		}
	}
	return nil
}

// Chest returns one by id.
func (b BossConfig) Chest(id string) *BossChest {
	for i := range b.Chests {
		if b.Chests[i].ID == id {
			return &b.Chests[i]
		}
	}
	return nil
}
