package gameconfig

// SocialConfig is Sosyal (social.json): the kingdom's hall, the friends' gift,
// the spyglass, the kingdom's aid and its shared goal.
//
// Two rules shape every number in here.
//
// Nothing in this document may be bought. A hall that sold a louder voice, or
// an aid stack for diamonds, would be the wallet's third door; validateSocial
// refuses a paid grant anywhere in it.
//
// Nothing in this document pays experience. The gift pays ENERGY, which is the
// only energy in it and is measured by scripts/pace.py against the daily
// budget; aid is a timed lane bonus (economy.AddTemp) and so is already capped
// where every timed bonus is. A kingdom that levelled its members would make
// choosing a big kingdom the game.
//
// The friends gate is a progression.sections row named here and never repeated
// (SectionLevel reads it). The hall's own gate is a KINGDOM, which is not a
// level and so is not a section at all.
type SocialConfig struct {
	Chat    ChatConfig    `json:"chat"`
	Friends FriendsConfig `json:"friends"`
	Spy     SpyConfig     `json:"spy"`
	Aid     AidConfig     `json:"aid"`
	Goal    GoalConfig    `json:"goal"`
}

// ------------------------------------------------------------------ the hall

// ChatConfig is what a line may be, how fast it may be said, and what happens
// to a lord who will not keep to it.
type ChatConfig struct {
	MaxChars      int `json:"max_chars"`
	History       int `json:"history"`
	RetentionDays int `json:"retention_days"`

	// The bucket: Burst lines ready, one back every RefillSeconds, and never
	// more than WindowMax in WindowMinutes whatever the bucket says. The window
	// is what stops a lord who waits two minutes and then empties a full bucket
	// into the hall.
	Burst         int `json:"burst"`
	RefillSeconds int `json:"refill_seconds"`
	WindowMinutes int `json:"window_minutes"`
	WindowMax     int `json:"window_max"`

	// A masked word costs nothing. A blocked one is a strike, and
	// StrikesToMute of them inside StrikeWindowHours shuts the hall for
	// MuteMinutes. The punishment is TIME, never gold or diamonds: a fine
	// would price bad words, and pricing them is selling them.
	StrikesToMute     int `json:"strikes_to_mute"`
	StrikeWindowHours int `json:"strike_window_hours"`
	MuteMinutes       int `json:"mute_minutes"`

	// ReportsToHide lords reporting one line hides it from everyone, before any
	// admin is awake. The moderation queue then decides whether it stays hidden.
	ReportsToHide         int `json:"reports_to_hide"`
	ReportCooldownMinutes int `json:"report_cooldown_minutes"`

	BlockedMax int `json:"blocked_max"`

	// The rules a lord agrees to before speaking, and the version they agreed
	// to. Raise the version and every lord is asked again -- which is what
	// App Review 1.2 asks of a hall whose rules have changed.
	RulesVersion int      `json:"rules_version"`
	RulesTitle   string   `json:"rules_title"`
	Rules        []string `json:"rules"`
	SupportEmail string   `json:"support_email"`
}

// ------------------------------------------------------------------- friends

// FriendsConfig is the roll and the one gift a day.
type FriendsConfig struct {
	// The progression.sections id that opens it.
	Section string `json:"section"`

	MaxFriends     int `json:"max_friends"`
	RequestsPerDay int `json:"requests_per_day"`
	PendingMax     int `json:"pending_max"`

	// A day old, both the account and the friendship. A farm of fresh accounts
	// gifting each other is the whole reason these two exist.
	MinAccountHours int `json:"min_account_hours"`
	MinFriendHours  int `json:"min_friend_hours"`

	// One gift a day to each friend, and this many taken.
	GiftsReceivedPerDay int `json:"gifts_received_per_day"`

	// A gift is a FLASK, named here and defined in rewards.tokens. Energy has
	// always entered this game through the pool, the day's refills and a flask,
	// and a gift is not a fourth door: it is a share of the TAKER's own pool,
	// so a level-60 friend cannot hand a new lord half a day.
	GiftToken string `json:"gift_token"`
}

// ------------------------------------------------------------ the spyglass

// SpyConfig is an hour's look at a rival's army, for gold.
//
// The gold is a sink and the rival is TOLD they were scouted: a camera nobody
// can feel is surveillance, and a move in a game is one the other lord can
// answer.
type SpyConfig struct {
	GoldPerLevel int64 `json:"gold_per_level"`
	Minutes      int   `json:"minutes"`
	PerDay       int   `json:"per_day"`
}

// Cost of scouting a lord of this level.
func (s SpyConfig) Cost(level int) int64 { return s.GoldPerLevel * int64(level) }

// ----------------------------------------------------------------- the aid

// AidConfig is a kingdom's own help: a stack of gold and experience for the
// lord who asked, and favour for the one who answered.
//
// The stack is a TIMED lane bonus filed by economy.AddTemp, so its ceiling is
// the timed lane's and not a new cap nobody would remember to check.
type AidConfig struct {
	PerDay    int   `json:"per_day"`
	MaxStacks int   `json:"max_stacks"`
	StackBP   int64 `json:"stack_bp"`
	Hours     int   `json:"hours"`

	// What answering is worth: kingdom favour, which buys nothing but the
	// kingdom's own shelf.
	FavourPerAid       int64 `json:"favour_per_aid"`
	AskCooldownMinutes int   `json:"ask_cooldown_minutes"`
}

// --------------------------------------------------------------- the goal

// GoalConfig is one shared goal a day for a kingdom, with three chests.
type GoalConfig struct {
	Kinds []GoalKind `json:"kinds"`

	Hours      int `json:"hours"`
	ClaimHours int `json:"claim_hours"`
	MinMembers int `json:"min_members"`

	// The least a lord must have put in to claim: a share of an EQUAL share,
	// so a kingdom cannot be carried by one lord and claimed by thirty.
	MinShareOfEqualBP int64 `json:"min_share_of_equal_bp"`

	Tiers []GoalTier `json:"tiers"`
}

// GoalKind is one thing a kingdom can be asked to do together. PerMember is
// what one member is expected to add, and the target is that times the members
// the kingdom had when the goal was set -- a hall of thirty is not a hall of
// three with the same bar.
type GoalKind struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Icon      string `json:"icon"`
	Blurb     string `json:"blurb"`
	PerMember int64  `json:"per_member"`
}

// GoalTier is one chest on the goal's bar.
type GoalTier struct {
	AtBP  int64        `json:"at_bp"`
	Grant RewardBundle `json:"grant"`
}

// GoalKind by id, or nil.
func (g GoalConfig) Kind(id string) *GoalKind {
	for i := range g.Kinds {
		if g.Kinds[i].ID == id {
			return &g.Kinds[i]
		}
	}
	return nil
}
