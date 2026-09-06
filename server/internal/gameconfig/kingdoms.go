package gameconfig

// KingdomsConfig covers founding, levelling, donations and the shared upgrade
// tree. Kingdom upgrades feed the SAME additive buckets as Family upgrades, so
// the two stack without compounding and the bucket caps still hold.
type KingdomsConfig struct {
	FoundCost  int64            `json:"found_cost"`
	FoundLevel int              `json:"found_level"`
	MaxLevel   int              `json:"max_level"`
	Levels     []KingdomLevel   `json:"levels"`
	Upgrades   []Upgrade        `json:"upgrades"`
	Donation   DonationConfig   `json:"donation"`
	Reputation ReputationConfig `json:"reputation"`
	// What a donor gets back personally. Without it, donating is pure cost to
	// the individual and pure gain to the collective, and nobody donates.
	FavourShop []FavourGood `json:"favour_shop"`
}

type KingdomLevel struct {
	Level      int   `json:"level"`
	XPRequired int64 `json:"xp_required"`
	MemberCap  int   `json:"member_cap"`
}

type DonationConfig struct {
	DailyCapBase     int64 `json:"daily_cap_base"`
	DailyCapPerLevel int64 `json:"daily_cap_per_level"`
	XPPerGold        int64 `json:"xp_per_gold"`
	XPPerReputation  int64 `json:"xp_per_reputation"`
	FavourPerGold    int64 `json:"favour_per_gold"`
}

// FavourGood is one line of the Kingdom Shop.
type FavourGood struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Cost  int64  `json:"cost"`
	Blurb string `json:"blurb"`
	// Only the timed boost uses these.
	BP    int64 `json:"bp,omitempty"`
	Hours int64 `json:"hours,omitempty"`
}

type ReputationConfig struct {
	DailyCapPerMember int64 `json:"daily_cap_per_member"`
	DecayBPPerDay     int64 `json:"decay_bp_per_day"`
}

// Kingdom upgrade buckets that are not shared with the Family tree.
const (
	BucketReputation    = "reputation_bp"
	BucketMemberCapFlat = "member_cap_flat"
)

func (b *Bundle) KingdomUpgrade(id string) *Upgrade { return b.kingdomUpgradeByID[id] }

// KingdomLevelFor returns the level a kingdom has earned with this much XP, and
// the XP needed for the next one.
func (b *Bundle) KingdomLevelFor(xp int64) (level int, nextXP int64) {
	level = 1
	for _, l := range b.Kingdoms.Levels {
		if l.Level > 1 && xp >= l.XPRequired {
			level = l.Level
		}
	}
	for _, l := range b.Kingdoms.Levels {
		if l.Level == level+1 {
			return level, l.XPRequired
		}
	}
	return level, 0
}

// KingdomMemberCap is the roster limit at a level, plus any Royal Court bonus.
func (b *Bundle) KingdomMemberCap(level int, courtBonus int) int {
	for _, l := range b.Kingdoms.Levels {
		if l.Level == level {
			return l.MemberCap + courtBonus
		}
	}
	return 5 + courtBonus
}
