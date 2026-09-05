// Package gameconfig holds the tunable game rules.
//
// The rules are DATA, not code: the admin panel publishes new versions and the
// server hot-swaps them without a redeploy, and without a client update. The
// JSON embedded here is only the seed for version 1.
//
// Every multiplier in the bundle is an integer in basis points (10000 = 1.0x).
// Nothing in the economy is a float, so the server, the admin simulator and the
// client's optimistic display all compute the same number.
package gameconfig

import (
	"embed"
	"encoding/json"
	"fmt"
	"sort"
)

//go:embed seed/*.json
var seedFS embed.FS

// Bundle is the complete, validated set of game rules.
type Bundle struct {
	Version int `json:"version"`

	Jobs        JobsConfig        `json:"jobs"`
	Progression ProgressionConfig `json:"progression"`
	Tiers       TiersConfig       `json:"tiers"`
	Items       ItemsConfig       `json:"items"`
	Soldiers    SoldiersConfig    `json:"soldiers"`
	Estates     EstatesConfig     `json:"estates"`
	Kingdoms    KingdomsConfig    `json:"kingdoms"`

	// Derived lookups, built once at load so hot paths never scan a slice.
	jobByID            map[string]*Job
	jobsAsc            []*Job // by unlock level then order
	levelByIx          []Level
	itemByID           map[string]*ItemDef
	itemsBySlotTier    map[string][]*ItemDef
	tierByID           map[string]*Tier
	tierIDs            []string // ascending by rank
	soldierTypeByID    map[string]*SoldierType
	upgradeByID        map[string]*Upgrade
	holdingByID        map[string]*Holding
	kingdomUpgradeByID map[string]*Upgrade
}

type JobsConfig struct {
	Milestones []Milestone `json:"milestones"`
	Jobs       []Job       `json:"jobs"`
}

// Job is one row of the Collect ladder.
type Job struct {
	ID          string `json:"id"`
	Order       int    `json:"order"`
	Name        string `json:"name"`
	UnlockLevel int    `json:"unlock_level"`
	EnergyCost  int64  `json:"energy_cost"`
	BaseGold    int64  `json:"base_gold"`
	BaseXP      int64  `json:"base_xp"`
}

// Milestone is a mastery threshold. Bonuses REPLACE rather than stack: reaching
// 50 collects means +10% total, not +5% plus +10%.
type Milestone struct {
	Collects int64 `json:"collects"`
	BonusBP  int64 `json:"bonus_bp"`
}

type ProgressionConfig struct {
	LevelCap           int          `json:"level_cap"`
	Energy             EnergyConfig `json:"energy"`
	StatPointsPerLevel int             `json:"stat_points_per_level"`
	Treasury           TreasuryConfig  `json:"treasury"`
	LevelupDiamonds    int64           `json:"levelup_diamonds"`
	Avatars            []string        `json:"avatars"`
	Levels             []Level      `json:"levels"`
}

// HasAvatar reports whether a portrait id is one a player may choose.
//
// A player who picked a portrait that a LATER balance version drops keeps it:
// this gates the choice, not the display. Rewriting stored rows on a config
// change would make a rollback lossy.
func (b *Bundle) HasAvatar(id string) bool {
	for _, a := range b.Progression.Avatars {
		if a == id {
			return true
		}
	}
	return false
}

// DefaultAvatar is what a new player starts with and what the client falls back
// to when it cannot resolve a stored one.
func (b *Bundle) DefaultAvatar() string {
	if len(b.Progression.Avatars) == 0 {
		return "knight"
	}
	return b.Progression.Avatars[0]
}

type TreasuryConfig struct {
	DepositFeeBP int64 `json:"deposit_fee_bp"`
}

type EnergyConfig struct {
	BaseMax          int64 `json:"base_max"`
	PerStatPoint     int64 `json:"per_stat_point"`
	RegenBaseSeconds int64 `json:"regen_base_seconds"`
	Overflow         bool  `json:"overflow"`
	LevelupRefill    bool  `json:"levelup_refill"`
	RegenBonusCapBP  int64 `json:"regen_bonus_cap_bp"`
}

type Level struct {
	Level        int   `json:"level"`
	XPToNext     int64 `json:"xp_to_next"`
	CumulativeXP int64 `json:"cumulative_xp"`
}

type TiersConfig struct {
	Tiers []Tier `json:"tiers"`
}

type Tier struct {
	ID       string  `json:"id"`
	Rank     int     `json:"rank"`
	Name     string  `json:"name"`
	Color    string  `json:"color"`
	Pips     int     `json:"pips"`
	StatMult float64 `json:"stat_mult"`
}

// LoadSeed parses the embedded seed bundle. It is the source of config
// version 1; later versions come from the database.
func LoadSeed() (*Bundle, error) {
	b := &Bundle{Version: 1}

	for _, f := range []struct {
		name string
		into any
	}{
		{"seed/jobs.json", &b.Jobs},
		{"seed/progression.json", &b.Progression},
		{"seed/tiers.json", &b.Tiers},
		{"seed/items.json", &b.Items},
		{"seed/soldiers.json", &b.Soldiers},
		{"seed/estates.json", &b.Estates},
		{"seed/kingdoms.json", &b.Kingdoms},
	} {
		raw, err := seedFS.ReadFile(f.name)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", f.name, err)
		}
		if err := json.Unmarshal(raw, f.into); err != nil {
			return nil, fmt.Errorf("parse %s: %w", f.name, err)
		}
	}

	if err := b.build(); err != nil {
		return nil, err
	}
	return b, b.Validate()
}

// build populates the derived lookups.
func (b *Bundle) build() error {
	b.jobByID = make(map[string]*Job, len(b.Jobs.Jobs))
	b.jobsAsc = make([]*Job, 0, len(b.Jobs.Jobs))
	for i := range b.Jobs.Jobs {
		j := &b.Jobs.Jobs[i]
		if _, dup := b.jobByID[j.ID]; dup {
			return fmt.Errorf("duplicate job id %q", j.ID)
		}
		b.jobByID[j.ID] = j
		b.jobsAsc = append(b.jobsAsc, j)
	}
	sort.Slice(b.jobsAsc, func(i, k int) bool {
		if b.jobsAsc[i].UnlockLevel != b.jobsAsc[k].UnlockLevel {
			return b.jobsAsc[i].UnlockLevel < b.jobsAsc[k].UnlockLevel
		}
		return b.jobsAsc[i].Order < b.jobsAsc[k].Order
	})

	// Index levels by level number for O(1) lookup.
	b.levelByIx = make([]Level, b.Progression.LevelCap+1)
	for _, l := range b.Progression.Levels {
		if l.Level >= 1 && l.Level <= b.Progression.LevelCap {
			b.levelByIx[l.Level] = l
		}
	}

	b.tierByID = make(map[string]*Tier, len(b.Tiers.Tiers))
	b.tierIDs = b.tierIDs[:0]
	sort.Slice(b.Tiers.Tiers, func(i, k int) bool { return b.Tiers.Tiers[i].Rank < b.Tiers.Tiers[k].Rank })
	for i := range b.Tiers.Tiers {
		t := &b.Tiers.Tiers[i]
		b.tierByID[t.ID] = t
		b.tierIDs = append(b.tierIDs, t.ID)
	}

	b.itemByID = make(map[string]*ItemDef, len(b.Items.Definitions))
	b.itemsBySlotTier = make(map[string][]*ItemDef)
	for i := range b.Items.Definitions {
		d := &b.Items.Definitions[i]
		if _, dup := b.itemByID[d.ID]; dup {
			return fmt.Errorf("duplicate item id %q", d.ID)
		}
		b.itemByID[d.ID] = d
		key := d.Slot + "/" + d.Tier
		b.itemsBySlotTier[key] = append(b.itemsBySlotTier[key], d)
	}

	b.soldierTypeByID = make(map[string]*SoldierType, len(b.Soldiers.Types))
	for i := range b.Soldiers.Types {
		t := &b.Soldiers.Types[i]
		b.soldierTypeByID[t.ID] = t
	}

	b.upgradeByID = make(map[string]*Upgrade, len(b.Estates.Upgrades))
	for i := range b.Estates.Upgrades {
		u := &b.Estates.Upgrades[i]
		if len(u.Costs) != u.MaxLevel {
			return fmt.Errorf("upgrade %q has %d costs for %d levels", u.ID, len(u.Costs), u.MaxLevel)
		}
		b.upgradeByID[u.ID] = u
	}
	b.holdingByID = make(map[string]*Holding, len(b.Estates.Holdings))
	for i := range b.Estates.Holdings {
		h := &b.Estates.Holdings[i]
		if len(h.Costs) != h.MaxLevel {
			return fmt.Errorf("holding %q has %d costs for %d levels", h.ID, len(h.Costs), h.MaxLevel)
		}
		b.holdingByID[h.ID] = h
	}

	b.kingdomUpgradeByID = make(map[string]*Upgrade, len(b.Kingdoms.Upgrades))
	for i := range b.Kingdoms.Upgrades {
		u := &b.Kingdoms.Upgrades[i]
		if len(u.Costs) != u.MaxLevel {
			return fmt.Errorf("kingdom upgrade %q has %d costs for %d levels", u.ID, len(u.Costs), u.MaxLevel)
		}
		b.kingdomUpgradeByID[u.ID] = u
	}

	// Milestones must be ascending so the "highest reached" scan is a simple walk.
	sort.Slice(b.Jobs.Milestones, func(i, k int) bool {
		return b.Jobs.Milestones[i].Collects < b.Jobs.Milestones[k].Collects
	})
	return nil
}

// Job returns the job with this id, or nil.
func (b *Bundle) Job(id string) *Job { return b.jobByID[id] }

// JobsForLevel returns every job unlocked at or below level, ordered by unlock.
func (b *Bundle) JobsForLevel(level int) []*Job {
	out := make([]*Job, 0, len(b.jobsAsc))
	for _, j := range b.jobsAsc {
		if j.UnlockLevel <= level {
			out = append(out, j)
		}
	}
	return out
}

// XPToNext returns the XP needed to advance from level, or 0 at the cap.
func (b *Bundle) XPToNext(level int) int64 {
	if level < 1 || level >= b.Progression.LevelCap {
		return 0
	}
	return b.levelByIx[level].XPToNext
}

// MilestoneBonusBP returns the mastery bonus for a job at this collect count.
// Bonuses replace rather than stack, so this is the highest threshold reached.
func (b *Bundle) MilestoneBonusBP(collects int64) int64 {
	var bp int64
	for _, m := range b.Jobs.Milestones {
		if collects >= m.Collects {
			bp = m.BonusBP
		} else {
			break
		}
	}
	return bp
}

// NextMilestone returns the next unreached threshold, or nil if all are done.
func (b *Bundle) NextMilestone(collects int64) *Milestone {
	for i := range b.Jobs.Milestones {
		if collects < b.Jobs.Milestones[i].Collects {
			return &b.Jobs.Milestones[i]
		}
	}
	return nil
}
