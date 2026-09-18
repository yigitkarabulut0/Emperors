package gameconfig

// The talent tree (balance/talents.json, Wave 7).
//
// A point every three levels from ten, and one for each Legacy: twenty-seven
// against fifty-one ranks, so the tree is a choice and never a checklist.
//
// Every rank feeds a channel the game ALREADY has -- the same bucket names the
// Family's upgrades use -- and is folded in exactly where an upgrade is, in the
// permanent lane, under the same caps. A talent that invented its own channel
// would be a second place a percentage is applied, which is the one thing the
// bucket rule exists to forbid.

// TalentsConfig is the tree and what it costs to change your mind.
type TalentsConfig struct {
	Section string `json:"section"`
	// The first level that pays a point, and how often one comes after it.
	FirstLevel     int64 `json:"first_level"`
	LevelsPerPoint int64 `json:"levels_per_point"`
	PointPerLegacy int64 `json:"point_per_legacy"`
	// Points that must be spent IN A BRANCH before its nth tier opens.
	TierGates []int `json:"tier_gates"`

	Respec TalentRespec `json:"respec"`

	Branches []TalentBranch `json:"branches"`
}

// TalentRespec is the gold a lord pays to take it all back: it doubles each
// time, to a ceiling, so changing your mind is a decision and not a habit.
type TalentRespec struct {
	BaseGold int64 `json:"base_gold"`
	StepBP   int64 `json:"step_bp"`
	MaxGold  int64 `json:"max_gold"`
}

// TalentBranch is one of the three.
type TalentBranch struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Blurb   string   `json:"blurb"`
	Talents []Talent `json:"talents"`
}

// Talent is one node: a bucket, what a rank is worth, and how many ranks.
type Talent struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Tier   int    `json:"tier"`
	Bucket string `json:"bucket"`
	// What ONE rank is worth, in the bucket's own units (basis points for a
	// percentage, whole units for max_energy_flat, minutes for the storehouse).
	PerRank int64  `json:"per_rank"`
	Ranks   int    `json:"ranks"`
	Blurb   string `json:"blurb"`
}

// Talent returns a node by id, with the branch it belongs to.
func (t TalentsConfig) Talent(id string) (*Talent, *TalentBranch) {
	for bi := range t.Branches {
		for ti := range t.Branches[bi].Talents {
			if t.Branches[bi].Talents[ti].ID == id {
				return &t.Branches[bi].Talents[ti], &t.Branches[bi]
			}
		}
	}
	return nil, nil
}

// Branch returns a branch by id.
func (t TalentsConfig) Branch(id string) *TalentBranch {
	for i := range t.Branches {
		if t.Branches[i].ID == id {
			return &t.Branches[i]
		}
	}
	return nil
}

// TotalRanks is every rank in the tree.
func (t TalentsConfig) TotalRanks() int {
	n := 0
	for _, b := range t.Branches {
		for _, x := range b.Talents {
			n += x.Ranks
		}
	}
	return n
}

// PointsAt is how many points a lord of this level and this many Legacies has
// been given. What they have SPENT is the database's business.
func (t TalentsConfig) PointsAt(level, legacy int64) int64 {
	if level < t.FirstLevel || t.LevelsPerPoint <= 0 {
		return legacy * t.PointPerLegacy
	}
	return (level-t.FirstLevel)/t.LevelsPerPoint + 1 + legacy*t.PointPerLegacy
}

// TierOpensAt is the points a branch needs before its nth tier (1-based) opens.
func (t TalentsConfig) TierOpensAt(tier int) int {
	if tier <= 0 || tier > len(t.TierGates) {
		return 0
	}
	return t.TierGates[tier-1]
}

// The forge (balance/forge.json, Wave 7).
//
// Three pieces of the same slot and rank, and gold worth a share of what the
// rank above sells for, make one piece of that rank. The gold is what stops it
// being a machine, and validate_forge.go proves the round trip always loses
// rather than trusting it.

// ForgeConfig is the whole of it.
type ForgeConfig struct {
	Section string `json:"section"`
	Pieces  int    `json:"pieces"`
	// The fee, as a share of the next rank's shop price.
	FeeBPOfNextPrice int64 `json:"fee_bp_of_next_price"`
	// The rungs that may be forged. Special is not among them: there is
	// nothing above it.
	Tiers []string `json:"tiers"`
	// The piece that comes out takes the highest mark of the three, and rolls
	// its quality and its masterwork afresh -- with the odds published.
	KeepsHighestILvl   bool         `json:"keeps_highest_ilvl"`
	Quality            QualityRange `json:"quality"`
	MasterworkChanceBP int64        `json:"masterwork_chance_bp"`
}

// CanForge reports a tier the forge will take.
func (f ForgeConfig) CanForge(tier string) bool {
	for _, t := range f.Tiers {
		if t == tier {
			return true
		}
	}
	return false
}
