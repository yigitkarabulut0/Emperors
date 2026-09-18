package gameconfig

// PvPConfig is Rekabet (pvp.json): the Honour Arena's ladder, the Bounty
// Board's purse and its leashes, and the Throne that a week of war crowns.
//
// Unlock levels are NOT here. Every level gate in the game is a
// progression.sections row read through Bundle.SectionLevel, and a second copy
// of the number is how tiers.json's stat_mult came to disagree with the curve
// the game ran on. Each section here NAMES its gate and validatePvP holds the
// named gate to the order the three features must open in.
//
// Neither are the boards: every board in the game lives in liveops.ranks, and a
// parallel list here would mean service.timedBoards had two sources.
type PvPConfig struct {
	Arena  ArenaConfig  `json:"arena"`
	Bounty BountyConfig `json:"bounty"`
	Throne ThroneConfig `json:"throne"`
}

// ---------------------------------------------------------------- the arena

// ArenaConfig is the Honour Arena: a ladder that touches no gold, costs no
// energy, and neither applies nor breaks a shield.
type ArenaConfig struct {
	// The progression.sections id that opens it.
	Section string `json:"section"`

	// Fights a day. Never buyable: there is no diamond price and no paid token
	// carries one, because a ladder whose rungs are for sale measures a wallet.
	// The hour's Honour Hour adds one, and that is the only way past this.
	TicketsPerDay   int `json:"tickets_per_day"`
	RefreshesPerDay int `json:"refreshes_per_day"`
	OpponentsShown  int `json:"opponents_shown"`

	StartRating int   `json:"start_rating"`
	FloorRating int   `json:"floor_rating"`
	MaxRating   int   `json:"max_rating"`
	KFactor     int   `json:"k_factor"`
	DefenderKBP int64 `json:"defender_k_bp"`

	// Matchmaking: a window of BandRating either side, widened BandWiden a step
	// up to BandSteps times before the hired champion is offered. RepeatBlock is
	// how many of a lord's last opponents are kept off their list -- two alts
	// trading wins is the one way a half-K ladder can be farmed.
	BandRating  int `json:"band_rating"`
	BandWiden   int `json:"band_widen"`
	BandSteps   int `json:"band_steps"`
	RepeatBlock int `json:"repeat_block"`

	// The share of the distance from StartRating a rating KEEPS when a season
	// turns: 5000 is half way back.
	ResetBP int64 `json:"reset_bp"`

	Leagues []ArenaLeague `json:"leagues"`

	// What a fight pays. Never experience, never energy: the arena is
	// deliberately outside scripts/pace.py's budget, and a grant that levelled
	// a lord would put it back inside without anyone measuring it.
	FirstWin  RewardBundle `json:"first_win"`
	WinGrant  RewardBundle `json:"win_grant"`
	LossGrant RewardBundle `json:"loss_grant"`

	// Rating milestones, paid once a season (app.arena.milestones is the mask,
	// cleared by the half reset).
	Milestones []ArenaMilestone `json:"milestones"`

	Bot ArenaBot `json:"bot"`
}

// ArenaLeague is one band of the ladder. AtRating is the rating it opens at;
// TopN, when set, ALSO demands a place on the ladder -- the last league is a
// place as well as a number, so it stays scarce however far ratings drift.
type ArenaLeague struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	AtRating int    `json:"at_rating"`
	TopN     int    `json:"top_n,omitempty"`
	// Its emblem's art key ("arena/league_<id>"), drawn beside the rating.
	Emblem string `json:"emblem"`
	// A frame worn while the league is held; empty for none.
	Cosmetic string `json:"cosmetic,omitempty"`
}

// ArenaMilestone is a rating reached, paid once a season.
type ArenaMilestone struct {
	Rating int          `json:"rating"`
	Grant  RewardBundle `json:"grant"`
}

// ArenaBot is the hired champion offered when the band holds nobody.
//
// Not a seeded app.players bot: a bot row would need a rating of its own, and
// bots are excluded from every board in the game. This one is built from the
// asker's own army, as guide.banditArmy is, and neither takes nor gives a
// rating to anybody but the lord who hired it.
type ArenaBot struct {
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	// Its strength as a share of the asker's own Might.
	MightBP int64 `json:"might_bp"`
	// What beating it moves, as a share of an ordinary fight's swing: a ladder
	// climbed on a champion nobody hired is not a ladder.
	RatingBP int64 `json:"rating_bp"`
}

// League returns the league with this id, or nil.
func (a ArenaConfig) League(id string) *ArenaLeague {
	for i := range a.Leagues {
		if a.Leagues[i].ID == id {
			return &a.Leagues[i]
		}
	}
	return nil
}

// --------------------------------------------------------------- the bounty

// BountyConfig is the Bounty Board: a gold SINK dressed as a grudge.
type BountyConfig struct {
	Section string `json:"section"`

	// The smallest bounty, and the plates the board offers. The client never
	// types an amount: it names a plate and the server prices it.
	MinAmount int64         `json:"min_amount"`
	Plates    []BountyPlate `json:"plates"`
	// The placer's fee, on top of the bounty, BURNED. Zero is refused: a bounty
	// with no fee is a way to move gold between two accounts for nothing, and
	// the burn is the only thing that makes this a sink.
	FeeBP int64 `json:"fee_bp"`
	Hours int   `json:"hours"`
	// One claim draws at most this many raid caps (service.raidCap).
	ClaimCapMultiple int64 `json:"claim_cap_multiple"`
	PlacesPerDay     int   `json:"places_per_day"`
	OpenPerTarget    int   `json:"open_per_target"`

	// --- the leashes ---
	// Never punching down: the hunter may be at most MaxLevelsAbove the
	// target's level, and the target's Might at least MinTargetMightBP of the
	// hunter's.
	MaxLevelsAbove    int   `json:"max_levels_above"`
	MinTargetMightBP  int64 `json:"min_target_might_bp"`
	ClaimsPerTarget   int   `json:"claims_per_target"`
	CooldownMinutes   int   `json:"cooldown_minutes"`
	PairClaimsPerWeek int   `json:"pair_claims_per_week"`
	MinAccountHours   int   `json:"min_account_hours"`

	// false: a shield stops a bounty hunt, as it stops a raid -- the owner's
	// decision, and the 48 hours outlast any shield sold. true: a hunt goes
	// through it, as a revenge strike does. Read in exactly one place
	// (service.raidOpts.ignoresShield).
	IgnoresShield bool `json:"ignores_shield"`
}

// BountyPlate is one amount the board offers, prepared by the server.
type BountyPlate struct {
	ID     string `json:"id"`
	Amount int64  `json:"amount"`
}

// Plate returns the plate with this id, or nil.
func (b BountyConfig) Plate(id string) *BountyPlate {
	for i := range b.Plates {
		if b.Plates[i].ID == id {
			return &b.Plates[i]
		}
	}
	return nil
}

// Cost is what placing a bounty of this amount takes from the purse: the escrow
// plus the fee that is burned. The one place it is priced -- the board's plate
// prints it and PlaceBounty charges it.
func (b BountyConfig) Cost(amount int64) (escrow, fee, total int64) {
	fee = amount * b.FeeBP / 10000
	return amount, fee, amount + fee
}

// --------------------------------------------------------------- the throne

// How the Throne is decided.
const (
	// Reputation GAINED in the week just closed (app.kingdom_week). Kingdom
	// reputation as it stands is cumulative and decays 2% a day, so "most on
	// Monday" would crown the same kingdom every Monday.
	ThroneWeekGain = "week_gain"
	// Reputation as it stands on the Monday (app.kingdoms.reputation).
	ThroneTotal = "total"
)

// Who a decree reaches.
const (
	ThroneScopeRealm   = "realm"
	ThroneScopeKingdom = "kingdom"
	ThroneScopeEmperor = "emperor"
)

// ThroneConfig is Emperor of the Week.
type ThroneConfig struct {
	// The first Monday (UTC) a reign may be settled for, "2006-01-02". A week
	// that began before the Throne existed was not played for, so it is never
	// crowned -- the rule liveops.season.epoch sets for the boards.
	Epoch      string `json:"epoch"`
	MinMembers int    `json:"min_members"`
	ReignDays  int    `json:"reign_days"`

	// week_gain | total.
	Measure string `json:"measure"`
	// realm | kingdom | emperor.
	DecreeScope     string `json:"decree_scope"`
	DecreesPerReign int    `json:"decrees_per_reign"`

	Decrees []ThroneDecree `json:"decrees"`

	// Worn through the reign, then taken off by the cosmetics_lapse job.
	EmperorFrame string `json:"emperor_frame"`
	EmperorTitle string `json:"emperor_title"`
	CourtTitle   string `json:"court_title"`

	// Sent as a letter's attachment, so the one reward path checks it and a
	// full armory never half-pays a crowning.
	EmperorGrant RewardBundle `json:"emperor_grant"`
	CourtGrant   RewardBundle `json:"court_grant"`

	PastReignsShown int `json:"past_reigns_shown"`
}

// ThroneDecree is one edict. It rides the TIMED lane, exactly as an hourly
// boost does (service.addLiveBonus), so its ceiling is the timed lane's and a
// lord already at the permanent cap still feels it.
type ThroneDecree struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Blurb   string `json:"blurb"`
	Icon    string `json:"icon"`
	Bucket  string `json:"bucket"`
	BP      int64  `json:"bp"`
	Minutes int    `json:"minutes"`
}

// Decree returns the decree with this id, or nil.
func (t ThroneConfig) Decree(id string) *ThroneDecree {
	for i := range t.Decrees {
		if t.Decrees[i].ID == id {
			return &t.Decrees[i]
		}
	}
	return nil
}
