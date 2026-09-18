package gameconfig

// LiveOpsConfig is the realm's calendar (liveops.json): the hourly event, the
// calendar's festivals, the season and its Royal Charter, the boards and the
// season's nobility, and the deeds (achievements).
type LiveOpsConfig struct {
	Hourly           HourlyConfig   `json:"hourly"`
	Events           EventsConfig   `json:"events"`
	Season           SeasonConfig   `json:"season"`
	Ranks            RanksConfig    `json:"ranks"`
	Achievements     []Achievement  `json:"achievements"`
	AchievementTiers []RewardBundle `json:"achievement_tiers"`
}

// Hourly effect kinds: what an hourly event does while it runs.
const (
	HourlyBoost           = "boost"            // a timed bonus in Bucket (collect_income_bp, xp_bp, luck_bp)
	HourlyRefillDiscount  = "refill_discount"  // the day's refills cost BP less
	HourlyFreeReroll      = "free_reroll"      // Count market rerolls for nothing, once each
	HourlyQuestMultiplier = "quest_multiplier" // the day's quests count X times over
	HourlyGift            = "gift"             // Grant, claimed once while it runs
)

// HourlyConfig is the table rolled at each hour's top.
type HourlyConfig struct {
	Table []HourlyEvent `json:"table"`
	// Never the same event two hours running.
	NoRepeat bool `json:"no_repeat"`
}

// HourlyEvent is one row of the table. The row with id "none" is the hour
// with no event, and carries only its chance.
type HourlyEvent struct {
	ID      string       `json:"id"`
	Name    string       `json:"name,omitempty"`
	Blurb   string       `json:"blurb,omitempty"`
	Icon    string       `json:"icon,omitempty"`
	Minutes int          `json:"minutes,omitempty"`
	BP      int64        `json:"bp"`
	Effect  HourlyEffect `json:"effect"`
}

// HourlyEffect is what an hourly event does.
type HourlyEffect struct {
	Kind   string       `json:"kind,omitempty"`
	Bucket string       `json:"bucket,omitempty"`
	BP     int64        `json:"bp,omitempty"`
	Count  int          `json:"count,omitempty"`
	X      int64        `json:"x,omitempty"`
	Grant  RewardBundle `json:"grant,omitempty"`
}

// HourlyNone is the table's row for an hour with nothing on.
const HourlyNone = "none"

// HourlyEvent returns the table row with this id, or nil.
func (h HourlyConfig) Event(id string) *HourlyEvent {
	for i := range h.Table {
		if h.Table[i].ID == id {
			return &h.Table[i]
		}
	}
	return nil
}

// EventsConfig is the calendar's festivals.
type EventsConfig struct {
	Templates []EventTemplate `json:"templates"`
	// How far ahead a scheduled festival is announced.
	AnnounceHours int `json:"announce_hours"`
	// How many places a festival's board shows.
	TopShown int `json:"top_shown"`
}

// EventTemplate is a festival, frozen into the event when it is scheduled.
type EventTemplate struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Theme string `json:"theme"`
	Blurb string `json:"blurb"`
	Days  int    `json:"days"`
	// The realm-wide bonus while it runs: collect_income_bp and xp_bp in their
	// timed lanes; reputation_bp and shop_discount_bp added to theirs.
	Effect     EventEffect      `json:"effect"`
	Points     []PointSource    `json:"points"`
	DailyCap   int64            `json:"daily_cap"`
	Tasks      []EventTask      `json:"tasks"`
	Milestones []EventMilestone `json:"milestones"`
	Ranks      []RankReward     `json:"ranks"`
}

// EventEffect is a festival's bonus.
type EventEffect struct {
	Bucket string `json:"bucket"`
	BP     int64  `json:"bp"`
}

// PointSource is Points for every Per of a deed.
type PointSource struct {
	Deed   string `json:"deed"`
	Points int64  `json:"points"`
	Per    int64  `json:"per"`
}

// EventTask is one of a festival's five goals.
type EventTask struct {
	ID     string       `json:"id"`
	Name   string       `json:"name"`
	Short  string       `json:"short"`
	Icon   string       `json:"icon"`
	Deed   string       `json:"deed"`
	Target int64        `json:"target"`
	Grant  RewardBundle `json:"grant"`
}

// EventMilestone opens at At points.
type EventMilestone struct {
	At    int64        `json:"at"`
	Grant RewardBundle `json:"grant"`
}

// RankReward pays every place from the previous row's Top+1 down to Top.
type RankReward struct {
	Top   int          `json:"top"`
	Grant RewardBundle `json:"grant"`
}

// SeasonConfig is the season and its Royal Charter.
type SeasonConfig struct {
	// Season 1's first day (a Monday, UTC), "2006-01-02".
	Epoch         string        `json:"epoch"`
	Days          int           `json:"days"`
	Tiers         int           `json:"tiers"`
	PointsPerTier int64         `json:"points_per_tier"`
	DailyCap      int64         `json:"daily_cap"`
	Sources       []PointSource `json:"sources"`
	// The royal lane: diamonds, or the product that unlocks it for the season.
	RoyalDiamonds int64  `json:"royal_diamonds"`
	RoyalProduct  string `json:"royal_product"`
	// The tier whose lords are the next season's Knights.
	KnightTier int            `json:"knight_tier"`
	Free       []RewardBundle `json:"free"`
	Royal      []RewardBundle `json:"royal"`
}

// RanksConfig is the boards and the season's nobility.
type RanksConfig struct {
	Weekly   []BoardDef     `json:"weekly"`
	Season   []BoardDef     `json:"season"`
	Nobility []NobilityRank `json:"nobility"`
}

// BoardDef is one board: its deed's count over the period, paid by place when
// the period closes. A season's board may instead count BoardRenown or
// BoardMightGain.
type BoardDef struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Deed    string       `json:"deed"`
	Rewards []RankReward `json:"rewards"`
}

// What a season's board may count besides a deed: its Charter points, and
// the Might a lord has gained since their first deed of the season.
const (
	BoardRenown    = "renown"
	BoardMightGain = "might_gain"
	// The peak rating a lord reached in the Honour Arena this season.
	BoardArenaRating = "arena_rating"
)

// NobilityRank is one rank of the season's nobility: by place (Top), by share
// of the season's renown (TopPct), or by the Charter's tier (CharterTier).
type NobilityRank struct {
	ID          string `json:"id"`
	Top         int    `json:"top,omitempty"`
	TopPct      int    `json:"top_pct,omitempty"`
	CharterTier int    `json:"charter_tier,omitempty"`
}

// Achievement is one deed in four tiers: a lifetime count of Deed, or a Stat
// read off the lord's state.
type Achievement struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Category string  `json:"category"`
	Icon     string  `json:"icon"`
	Blurb    string  `json:"blurb"`
	Deed     string  `json:"deed,omitempty"`
	Stat     string  `json:"stat,omitempty"`
	Tiers    []int64 `json:"tiers"`
	// The fourth tier's title.
	Title string `json:"title"`
}

// Achievement stats: what is read off a lord's state rather than counted.
const (
	StatLevel      = "level"
	StatMight      = "might"
	StatMasteries  = "masteries"
	StatCollection = "collection"
)

// Achievement categories, deeds.png's seven medallions.
var AchievementCategories = []string{"work", "war", "kingdom", "crown", "scroll", "laurel", "chest"}

// EventTemplate returns the festival template with this id, or nil.
func (e EventsConfig) Template(id string) *EventTemplate {
	for i := range e.Templates {
		if e.Templates[i].ID == id {
			return &e.Templates[i]
		}
	}
	return nil
}
