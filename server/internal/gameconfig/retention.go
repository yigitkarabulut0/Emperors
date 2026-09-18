package gameconfig

// RetentionConfig is the daily loop (retention.json): what brings a lord back
// each day and each week. All of it is free, and every grant in it pays through
// the one reward path, so CheckReward(grant, false) holds each one.
type RetentionConfig struct {
	Cart     CartConfig     `json:"cart"`
	Calendar CalendarConfig `json:"calendar"`
	Weekly   WeeklyConfig   `json:"weekly"`
	Frenzy   FrenzyConfig   `json:"frenzy"`
	Road     RoadConfig     `json:"road"`
	Guide    GuideConfig    `json:"guide"`
	Winback  WinbackConfig  `json:"winback"`
}

// CartConfig is the Tax Cart: one arrives every IntervalSeconds, Cap can wait,
// and each opens to one prize drawn from Odds (basis points, 10000 in all).
type CartConfig struct {
	UnlockLevel     int         `json:"unlock_level"`
	IntervalSeconds int64       `json:"interval_seconds"`
	Cap             int         `json:"cap"`
	Odds            []CartPrize `json:"odds"`
}

// CartPrize is one row of the cart's published odds.
type CartPrize struct {
	ID    string       `json:"id"`
	Name  string       `json:"name"`
	BP    int64        `json:"bp"`
	Grant RewardBundle `json:"grant"`
}

// Calendar square pictures, as calendar.png paints them.
const (
	SquareDiamonds = "diamonds"
	SquarePurse    = "purse"
	SquareFlask    = "flask"
	SquareScroll   = "scroll"
	SquareCart     = "cart"
	SquareCrown    = "crown"
)

// CalendarConfig is the 28-day login calendar.
type CalendarConfig struct {
	Squares []CalendarSquare `json:"squares"`
	// Days that may be missed and mended; more and the next claim starts anew.
	GraceDays int `json:"grace_days"`
	// The price of mending, by days missed (one entry per grace day).
	RestoreDiamonds []int64 `json:"restore_diamonds"`
	// Royal Pardons given with a cycle's first square, and the most held.
	PardonsPerCycle int64 `json:"pardons_per_cycle"`
	PardonsMax      int64 `json:"pardons_max"`
}

// CalendarSquare is one day of the 28.
type CalendarSquare struct {
	Kind  string       `json:"kind"`
	Crown bool         `json:"crown,omitempty"`
	Grant RewardBundle `json:"grant"`
}

// WeeklyConfig is the week's quests: Fixed are on every board, Draw more are
// drawn from Pool; each is worth Points toward Chests.
type WeeklyConfig struct {
	Fixed []WeeklyTask `json:"fixed"`
	Draw  int          `json:"draw"`
	// A task is offered when its min_level is at most max(level, this): what
	// the first sitting reaches is fair to ask of a new lord's week.
	EligibleLevelFloor int           `json:"eligible_level_floor"`
	Pool               []WeeklyTask  `json:"pool"`
	Chests             []WeeklyChest `json:"chests"`
}

// WeeklyTask is one of the week's quests: Target of a deed, counted over the
// lord's own week.
type WeeklyTask struct {
	ID string `json:"id"`
	// Name is the task's heading; Short says what to do, on one plate.
	Name     string       `json:"name"`
	Short    string       `json:"short"`
	Blurb    string       `json:"blurb"`
	Icon     string       `json:"icon"`
	Deed     string       `json:"deed"`
	Target   int64        `json:"target"`
	Points   int64        `json:"points"`
	MinLevel int          `json:"min_level,omitempty"`
	Grant    RewardBundle `json:"grant"`
}

// WeeklyChest opens at At points.
type WeeklyChest struct {
	At    int64        `json:"at"`
	Grant RewardBundle `json:"grant"`
}

// FrenzyConfig is the Golden Hour: a run of collects, none further apart than
// WindowSeconds, that spends FillPct of the pool lights it for DurationSeconds,
// in which collects pay BonusBP more gold (the timed lane) on up to CoverPct of
// the pool's energy. PerDay a day, CooldownSeconds apart.
type FrenzyConfig struct {
	UnlockLevel     int   `json:"unlock_level"`
	WindowSeconds   int64 `json:"window_seconds"`
	FillPct         int64 `json:"fill_pct"`
	DurationSeconds int64 `json:"duration_seconds"`
	BonusBP         int64 `json:"bonus_bp"`
	CoverPct        int64 `json:"cover_pct"`
	PerDay          int   `json:"per_day"`
	CooldownSeconds int64 `json:"cooldown_seconds"`
}

// RoadConfig is the Victory Road.
type RoadConfig struct {
	Milestones []RoadMilestone `json:"milestones"`
}

// RoadMilestone is claimed once, any time after Level is reached.
type RoadMilestone struct {
	Level int          `json:"level"`
	Crown bool         `json:"crown,omitempty"`
	Grant RewardBundle `json:"grant"`
}

// Guide step kinds: how a step is done.
const (
	GuideTap   = "tap"    // tapping on
	GuideDeed  = "deed"   // Count of Deed, in a lifetime
	GuideLevel = "level"  // reaching Level
	GuideWorn  = "worn"   // the hero wearing a piece of gear
	GuideFight = "bandit" // beating Karel the Bandit
)

// GuideConfig is the steward's guide through the first ten minutes.
type GuideConfig struct {
	Steps  []GuideStep  `json:"steps"`
	Finish RewardBundle `json:"finish"`
	// The most the steward pays toward a step's first purchase.
	PurseMax int64        `json:"purse_max"`
	Bandit   BanditConfig `json:"bandit"`
}

// GuideStep is one step.
type GuideStep struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Title string `json:"title"`
	// Text is the steward's words while the step waits; Done, once it is done.
	Text   string `json:"text"`
	Done   string `json:"done"`
	Tab    string `json:"tab,omitempty"`
	Target string `json:"target,omitempty"`
	Deed   string `json:"deed,omitempty"`
	Count  int64  `json:"count,omitempty"`
	Level  int    `json:"level,omitempty"`
	// The level the step's target opens at: below it, the lord works first.
	MinLevel int `json:"min_level,omitempty"`
	// The steward pays the shortfall toward the step's first purchase when
	// the step begins (buying gear, the first upgrade).
	Purse bool `json:"purse,omitempty"`
}

// BanditConfig is the guide's one fight: a bot that is not a lord.
type BanditConfig struct {
	Name    string       `json:"name"`
	Avatar  string       `json:"avatar"`
	Level   int64        `json:"level"`
	Seeds   int          `json:"seeds"`
	Attack  int64        `json:"attack"`
	Defense int64        `json:"defense"`
	Speed   int64        `json:"speed"`
	HP      int64        `json:"hp"`
	Grant   RewardBundle `json:"grant"`
}

// WinbackConfig is the welcome back: a letter for a lord away AwayDays or
// more, a second with LongGrant past LongAwayDays, once in CooldownDays.
type WinbackConfig struct {
	AwayDays     int          `json:"away_days"`
	LongAwayDays int          `json:"long_away_days"`
	CooldownDays int          `json:"cooldown_days"`
	Grant        RewardBundle `json:"grant"`
	LongGrant    RewardBundle `json:"long_grant"`
	Title        string       `json:"title"`
	Body         string       `json:"body"`
	LongTitle    string       `json:"long_title"`
	LongBody     string       `json:"long_body"`
}

// GuideStepIndex is the position of the step with this id, or -1.
func (g GuideConfig) GuideStepIndex(id string) int {
	for i := range g.Steps {
		if g.Steps[i].ID == id {
			return i
		}
	}
	return -1
}
