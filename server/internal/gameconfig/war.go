package gameconfig

// The kingdom wars (balance/war.json, Wave 8).
//
// Kingdoms are matched on a Friday evening by the Might of their best fifteen,
// never against more than one and a half times their own, and never the same
// pair twice running; the war itself runs Saturday to Monday.
//
// NOTHING of a lord's is at stake. No gold is stolen, a shield neither stops a
// war attack nor breaks on one, and the only thing that moves is points -- which
// is what lets a lord fight the biggest name on the other side without counting
// the cost, and what stops a war from being a raid with a banner on it.

// WarConfig is the whole of it.
type WarConfig struct {
	Section string `json:"section"`

	// When the pairs are drawn: the weekday (Monday is 0) and the hour, UTC.
	MatchWeekday int `json:"match_weekday"`
	MatchHour    int `json:"match_hour"`
	// How many days the war then runs.
	Days int `json:"days"`

	// How a kingdom is weighed for the draw, and how far a pair may be apart.
	TopMembers int   `json:"top_members"`
	MaxRatioBP int64 `json:"max_ratio_bp"`
	MinMembers int   `json:"min_members"`

	AttacksPerDay int `json:"attacks_per_day"`
	Banners       int `json:"banners"`
	// What beating a lord who has lost every banner is worth.
	RoutBP int64 `json:"rout_bp"`

	Points WarPoints `json:"points"`

	Won  WarPurse `json:"won"`
	Lost WarPurse `json:"lost"`
	// What the best lord of the week is called.
	WarlordTitle string `json:"warlord_title"`
}

// WarPoints is what each thing that happens in a war is worth.
type WarPoints struct {
	// A win pays this times the Might ratio, clamped between the two bounds:
	// punching up is worth more, farming down is worth less, and neither runs
	// away with the war.
	WinBase  int64 `json:"win_base"`
	RatioMin int64 `json:"ratio_min_bp"`
	RatioMax int64 `json:"ratio_max_bp"`
	Loss     int64 `json:"loss"`
	Held     int64 `json:"held"`
}

// WarPurse is what a side takes home.
type WarPurse struct {
	Grant      RewardBundle `json:"grant"`
	Reputation int64        `json:"reputation"`
	KingdomXP  int64        `json:"kingdom_xp"`
}
