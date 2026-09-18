// Package deeds names what a player does that something counts, and which
// stretches of time each count belongs to.
//
// Pure: the service records what this lays out.
package deeds

import (
	"sort"
	"time"
)

// Kind is one thing a player does.
type Kind string

// Every counted deed. A new counter is a new name here, never a new table.
const (
	Collects     Kind = "collects"
	Energy       Kind = "energy"
	XP           Kind = "xp"
	Raids        Kind = "raids"
	RaidWins     Kind = "raid_wins"
	RevengeWins  Kind = "revenge_wins"
	DefensesHeld Kind = "defenses_held"
	GoldStolen   Kind = "gold_stolen"
	Buys         Kind = "buys"
	ShopGold     Kind = "shop_gold"
	Sells        Kind = "sells"
	Recruits     Kind = "recruits"
	Rerolls      Kind = "rerolls"
	Upgrades     Kind = "upgrades"
	Holdings     Kind = "holdings"
	DonatedGold  Kind = "donated_gold"
	StatSpends   Kind = "stat_spends"
	DailyQuests  Kind = "daily_quests"
	DailyClaims  Kind = "daily_claims"
	MailClaims   Kind = "mail_claims"
	CartsOpened  Kind = "carts_opened"
	WeeklyQuests Kind = "weekly_quests"
	GoldenHours  Kind = "golden_hours"
	// Rekabet (Wave 5). ArenaFights and ArenaWins count the Honour Arena; the
	// bounty three count the board. BountyGold is what claims carried off, which
	// is the number the panel watches to see whether the sink is working.
	ArenaFights     Kind = "arena_fights"
	ArenaWins       Kind = "arena_wins"
	BountiesPlaced  Kind = "bounties_placed"
	BountiesClaimed Kind = "bounties_claimed"
	BountyGold      Kind = "bounty_gold"
	// Sosyal (Wave 6). Both count what a lord did FOR somebody else, which is
	// the only kind of deed the hall adds: nothing here counts words said.
	GiftsGiven Kind = "gifts_given"
	AidGiven   Kind = "aid_given"
	// PvE ve derinlik (Wave 7). A stage walked and a stage walked for the first
	// time are two different deeds: a day's quest may ask for either "fight
	// three stages" or "take a new mile", and one counter could not say both.
	// HuntsSent counts the tap, not the return, so a quest is done when the
	// lord has done their part and not eight hours later.
	CampaignStages Kind = "campaign_stages"
	CampaignFirsts Kind = "campaign_firsts"
	CampaignStars  Kind = "campaign_stars"
	HuntsSent      Kind = "hunts_sent"
	HuntsReturned  Kind = "hunts_returned"
	Forges         Kind = "forges"
	// Krallik Boss ve Savaslari (Wave 8). BossHits counts blows struck and
	// BossDamage what they took out of the beast, because "hit it six times"
	// and "hurt it most" are two different things to be proud of; BossKills is
	// the killing blow. WarAttacks and WarWins count a war attack, which is
	// NOT a raid and must never be counted as one: a raid moves gold and a war
	// attack moves nothing, and a board that added them together would say a
	// lord stole what they never touched.
	BossHits   Kind = "boss_hits"
	BossDamage Kind = "boss_damage"
	BossKills  Kind = "boss_kills"
	WarAttacks Kind = "war_attacks"
	WarWins    Kind = "war_wins"
)

// All is every counted deed, in the order above.
var All = []Kind{Collects, Energy, XP, Raids, RaidWins, RevengeWins, DefensesHeld, GoldStolen, Buys,
	ShopGold, Sells, Recruits, Rerolls, Upgrades, Holdings, DonatedGold, StatSpends, DailyQuests,
	DailyClaims, MailClaims, CartsOpened, WeeklyQuests, GoldenHours, ArenaFights, ArenaWins,
	BountiesPlaced, BountiesClaimed, BountyGold, GiftsGiven, AidGiven,
	CampaignStages, CampaignFirsts, CampaignStars, HuntsSent, HuntsReturned, Forges,
	BossHits, BossDamage, BossKills, WarAttacks, WarWins}

// Known reports whether a deed is one the game counts.
func Known(k Kind) bool {
	for _, a := range All {
		if a == k {
			return true
		}
	}
	return false
}

// Scopes: the stretches of time a counter is kept over.
const (
	ScopeLife   = "life"
	ScopeWeek   = "week"   // the player's local week, from Monday
	ScopeUWeek  = "uweek"  // the UTC week, from Monday: boards everyone shares
	ScopeSeason = "season" // a season, by its number: the season's boards
	ScopeEvent  = "event"  // a festival, by its id: its tasks
)

// Period is a stretch beyond the three every deed is counted for: the season
// running, the festival running.
type Period struct {
	Scope  string
	Period int64
}

// Deeds is what one action did: a count per kind.
type Deeds map[Kind]int64

// WeekStart is the Monday of the week a calendar day falls in.
func WeekStart(day time.Time) time.Time {
	back := (int(day.Weekday()) + 6) % 7 // Monday 0 ... Sunday 6
	return day.AddDate(0, 0, -back)
}

// EpochDay is a calendar day as whole days since 1970-01-01.
func EpochDay(day time.Time) int64 {
	return time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC).Unix() / 86400
}

// UWeek is the UTC week an instant falls in, as its Monday's epoch day: the
// period of the boards everyone shares.
func UWeek(now time.Time) int64 {
	u := now.UTC()
	return EpochDay(WeekStart(time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)))
}

// Rows lays one action's deeds out as the rows it adds to: every kind counted
// for a lifetime, for the player's local week and for the UTC week -- and for
// each further period running (the season, a festival). localDay is the
// player's calendar day; now is the instant, for the UTC week.
//
// Zero and negative counts are left out, and the output is sorted so the same
// deeds always write the same rows in the same order.
func Rows(dd Deeds, localDay, now time.Time, more ...Period) (scopes []string, periods []int64, kinds []string, values []int64) {
	week := EpochDay(WeekStart(localDay))
	uweek := UWeek(now)
	spans := append([]Period{{ScopeLife, 0}, {ScopeWeek, week}, {ScopeUWeek, uweek}}, more...)

	names := make([]string, 0, len(dd))
	for k, v := range dd {
		if v > 0 {
			names = append(names, string(k))
		}
	}
	sort.Strings(names)
	for _, n := range names {
		v := dd[Kind(n)]
		for _, sp := range spans {
			scopes = append(scopes, sp.Scope)
			periods = append(periods, sp.Period)
			kinds = append(kinds, n)
			values = append(values, v)
		}
	}
	return scopes, periods, kinds, values
}
