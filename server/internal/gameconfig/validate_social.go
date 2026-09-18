package gameconfig

import (
	"fmt"
	"strings"
)

// validateSocial checks Sosyal.
//
// Three rules are worth stating here, because all three are the kind that get
// "simplified" into a bug later.
//
// Nothing in this document is bought, so every grant is checked with paid=false
// -- the stricter of the two lists.
//
// Nothing in it pays EXPERIENCE. The friends' gift pays energy and is measured
// by scripts/pace.py against the daily budget; a kingdom's goal pays gold, a
// cart and diamonds. A grant that levelled a lord for standing in a big
// kingdom would make choosing a kingdom the game, so it is refused here rather
// than noticed later.
//
// The hall's punishment is TIME. A mute is minutes; nothing in chat may cost
// gold, diamonds or an item, because a fine prices bad words and pricing them
// is selling them. There is nothing to check in the grants for that -- chat has
// none, and this refuses the config that would give it one.
// KnownGoalKinds is what a kingdom's shared goal may watch.
//
// service/help.go switches on these names to turn an action into progress, and
// a name nothing switches on moves no bar at all -- a goal that sits at nought
// for a day with no error anywhere, which is what happened to the quests before
// KnownQuestKinds existed. gameconfig cannot import the service, so the list
// lives here and goal_kinds_test.go in the service holds the switch to it.
var KnownGoalKinds = []string{
	"energy", "victories",
	// PvE ve derinlik (Wave 7) and Krallik Boss (Wave 8).
	"campaign", "boss",
}

func knownGoalKind(k string) bool {
	for _, x := range KnownGoalKinds {
		if x == k {
			return true
		}
	}
	return false
}

func (b *Bundle) validateSocial() []string {
	var p []string
	s := b.Social

	grant := func(where string, g RewardBundle, mustPay bool) {
		if mustPay && g.Empty() {
			p = append(p, fmt.Sprintf("%s grants nothing", where))
		}
		for _, problem := range b.CheckReward(g, false) {
			p = append(p, fmt.Sprintf("%s: %s", where, problem))
		}
		if g.XP != 0 || g.XPWages != 0 {
			p = append(p, fmt.Sprintf("%s carries experience; a kingdom that levelled its members would make choosing a big kingdom the game", where))
		}
	}

	// --- the hall ---
	c := s.Chat
	if c.MaxChars < 40 || c.MaxChars > 500 {
		p = append(p, fmt.Sprintf("social.chat.max_chars is %d, outside 40..500: under 40 a hall cannot hold a sentence, over 500 one lord fills a screen", c.MaxChars))
	}
	if c.History < 10 || c.History > 200 {
		p = append(p, fmt.Sprintf("social.chat.history is %d, outside 10..200", c.History))
	}
	if c.RetentionDays < 1 || c.RetentionDays > 365 {
		p = append(p, fmt.Sprintf("social.chat.retention_days is %d, outside 1..365: the hall is swept, and what it keeps is what a report can still be read against", c.RetentionDays))
	}
	if c.Burst < 1 || c.Burst > 20 {
		p = append(p, fmt.Sprintf("social.chat.burst is %d, outside 1..20", c.Burst))
	}
	if c.RefillSeconds < 1 || c.RefillSeconds > 600 {
		p = append(p, fmt.Sprintf("social.chat.refill_seconds is %d, outside 1..600", c.RefillSeconds))
	}
	if c.WindowMinutes < 1 || c.WindowMinutes > 120 {
		p = append(p, fmt.Sprintf("social.chat.window_minutes is %d, outside 1..120", c.WindowMinutes))
	}
	if c.WindowMax < c.Burst {
		p = append(p, fmt.Sprintf("social.chat.window_max (%d) is under the burst (%d), so the bucket could never be emptied once", c.WindowMax, c.Burst))
	}
	// The window must be the harder of the two leashes, or it is decoration:
	// a bucket that refills faster than the window allows is what is actually
	// in force, and nobody would know which number to change.
	if c.RefillSeconds > 0 && c.WindowMinutes > 0 {
		if refilled := c.Burst + c.WindowMinutes*60/c.RefillSeconds; refilled <= c.WindowMax {
			p = append(p, fmt.Sprintf("social.chat: the bucket allows %d lines in %d minutes and the window allows %d, so the window never bites -- one of the two is decoration", refilled, c.WindowMinutes, c.WindowMax))
		}
	}
	if c.StrikesToMute < 1 || c.StrikesToMute > 10 {
		p = append(p, fmt.Sprintf("social.chat.strikes_to_mute is %d, outside 1..10", c.StrikesToMute))
	}
	if c.StrikeWindowHours < 1 || c.StrikeWindowHours > 168 {
		p = append(p, fmt.Sprintf("social.chat.strike_window_hours is %d, outside 1..168", c.StrikeWindowHours))
	}
	if c.MuteMinutes < 1 || c.MuteMinutes > 60*24*7 {
		p = append(p, fmt.Sprintf("social.chat.mute_minutes is %d, outside a minute and a week", c.MuteMinutes))
	}
	if c.ReportsToHide < 2 || c.ReportsToHide > 20 {
		p = append(p, fmt.Sprintf("social.chat.reports_to_hide is %d, outside 2..20: at 1 any lord could silence any other", c.ReportsToHide))
	}
	if c.ReportCooldownMinutes < 1 {
		p = append(p, "social.chat.report_cooldown_minutes is 0, which is the leash removed")
	}
	if c.BlockedMax < 10 {
		p = append(p, fmt.Sprintf("social.chat.blocked_max is %d: a lord must be able to block everyone they meet", c.BlockedMax))
	}
	if c.RulesVersion < 1 {
		p = append(p, "social.chat.rules_version is under 1, so no lord could ever have agreed to the current rules")
	}
	if strings.TrimSpace(c.RulesTitle) == "" || len(c.Rules) < 3 {
		p = append(p, "social.chat: the Rules of the Hall need a title and at least three lines -- App Review 1.2 asks for the rules and a way to report, shown where the talking is")
	}
	if !strings.Contains(c.SupportEmail, "@") {
		p = append(p, fmt.Sprintf("social.chat.support_email %q is not an address, and App Review 1.2 wants one beside the rules", c.SupportEmail))
	}

	// --- friends ---
	f := s.Friends
	friendsAt := 0
	if f.Section == "" {
		p = append(p, "social.friends.section names no progression.sections gate")
	} else {
		found := false
		for _, sec := range b.Progression.Sections {
			if sec.ID == f.Section {
				friendsAt, found = sec.Level, true
			}
		}
		if !found {
			p = append(p, fmt.Sprintf("social.friends.section names the gate %q, which progression.sections does not open", f.Section))
		}
	}
	if friendsAt > 10 {
		p = append(p, fmt.Sprintf("social.friends opens at level %d: the gift is a new lord's welcome, and a welcome that arrives at level %d is not one", friendsAt, friendsAt))
	}
	if f.MaxFriends < 1 || f.MaxFriends > 500 {
		p = append(p, fmt.Sprintf("social.friends.max_friends is %d, outside 1..500", f.MaxFriends))
	}
	if f.RequestsPerDay < 1 {
		p = append(p, "social.friends.requests_per_day is 0, which is the leash removed")
	}
	if f.PendingMax < 1 {
		p = append(p, "social.friends.pending_max is 0, so no request could ever wait")
	}
	if f.MinAccountHours < 1 || f.MinFriendHours < 1 {
		p = append(p, "social.friends: both min_account_hours and min_friend_hours must stand above zero, or a morning's fresh accounts can gift each other")
	}
	if f.GiftsReceivedPerDay < 1 {
		p = append(p, "social.friends.gifts_received_per_day is 0, so no gift could ever be taken")
	}
	// The gift is energy, and energy is the one thing the day's three refills
	// are supposed to bound. What a lord can take in a day is the draught's
	// share of their pool times this count, and scripts/pace.py measures it
	// against the hall's budget; this refuses the configuration it could not
	// measure its way out of.
	tok := b.Token(f.GiftToken)
	switch {
	case f.GiftToken == "":
		p = append(p, "social.friends.gift_token names no token, so a gift would carry nothing")
	case tok == nil:
		p = append(p, fmt.Sprintf("social.friends.gift_token names %q, which rewards.tokens does not define", f.GiftToken))
	case tok.EnergyPct <= 0:
		p = append(p, fmt.Sprintf("social.friends.gift_token names %q, which is not a flask: a gift is energy or it is nothing", f.GiftToken))
	case tok.PaidOK:
		p = append(p, fmt.Sprintf("social.friends.gift_token names %q, which money may carry; bought energy stays the day's three refills", f.GiftToken))
	default:
		if share := tok.EnergyPct * int64(f.GiftsReceivedPerDay); share > 15 {
			p = append(p, fmt.Sprintf("social.friends: a lord could take %d%% of their pool a day in gifts; scripts/pace.py measured 9%% at 2.1%% of casual level 60, against the hall's budget of 3%%", share))
		}
	}

	// --- the spyglass ---
	sp := s.Spy
	if sp.GoldPerLevel < 1 {
		p = append(p, "social.spy.gold_per_level is 0, which prices the spyglass at the floor rather than refusing to load")
	}
	if sp.Minutes < 1 || sp.Minutes > 60*24 {
		p = append(p, fmt.Sprintf("social.spy.minutes is %d, outside a minute and a day", sp.Minutes))
	}
	if sp.PerDay < 1 {
		p = append(p, "social.spy.per_day is 0, which is the leash removed")
	}

	// --- the aid ---
	a := s.Aid
	if a.PerDay < 1 {
		p = append(p, "social.aid.per_day is 0, which is the leash removed")
	}
	if a.MaxStacks < 1 || a.MaxStacks > 50 {
		p = append(p, fmt.Sprintf("social.aid.max_stacks is %d, outside 1..50", a.MaxStacks))
	}
	if a.StackBP < 1 {
		p = append(p, "social.aid.stack_bp is 0, so aid would be a button that does nothing")
	}
	// The whole stack is a timed lane bonus, and the timed lane's cap is what
	// finally bounds it -- but a stack that alone reaches the cap makes every
	// other timed bonus in the game worth nothing while it runs.
	if top := a.StackBP * int64(a.MaxStacks); top > MaxBoostGrantBP {
		p = append(p, fmt.Sprintf("social.aid: %d stacks of %d bp is %d bp, over the %d a boost may carry; the aid would eat the whole timed lane", a.MaxStacks, a.StackBP, top, MaxBoostGrantBP))
	}
	if a.Hours < 1 || a.Hours > 72 {
		p = append(p, fmt.Sprintf("social.aid.hours is %d, outside 1..72", a.Hours))
	}
	if a.FavourPerAid < 1 {
		p = append(p, "social.aid.favour_per_aid is 0: answering a call must be worth something to the one who answers")
	}
	if a.AskCooldownMinutes < 1 {
		p = append(p, "social.aid.ask_cooldown_minutes is 0, which is the leash removed")
	}

	// --- the shared goal ---
	g := s.Goal
	if len(g.Kinds) == 0 {
		p = append(p, "social.goal.kinds is empty -- the social section is missing or was not generated")
	}
	seen := map[string]bool{}
	for i, k := range g.Kinds {
		where := fmt.Sprintf("social.goal.kinds[%d]", i)
		if k.ID == "" || k.Name == "" || k.Blurb == "" {
			p = append(p, fmt.Sprintf("%s needs an id, a name and a blurb: the hall reads them out", where))
		}
		if seen[k.ID] {
			p = append(p, fmt.Sprintf("%s repeats the id %q", where, k.ID))
		}
		seen[k.ID] = true
		if k.PerMember < 1 {
			p = append(p, fmt.Sprintf("%s.per_member is 0, which sets a target of nothing", where))
		}
		if k.Icon == "" {
			p = append(p, fmt.Sprintf("%s names no icon", where))
		}
		if !knownGoalKind(k.ID) {
			p = append(p, fmt.Sprintf("%s watches %q, which nothing counts: the bar would sit "+
				"at nought all day and nothing would report an error", where, k.ID))
		}
	}
	if g.Hours < 1 || g.Hours > 72 {
		p = append(p, fmt.Sprintf("social.goal.hours is %d, outside 1..72", g.Hours))
	}
	if g.ClaimHours < g.Hours {
		p = append(p, fmt.Sprintf("social.goal.claim_hours (%d) is under the goal's own hours (%d), so a chest could close before the goal did", g.ClaimHours, g.Hours))
	}
	if g.MinMembers < 2 {
		p = append(p, "social.goal.min_members is under two: a kingdom of one is a lord, and a shared goal needs somebody to share it with")
	}
	if g.MinShareOfEqualBP < 1 || g.MinShareOfEqualBP > 10000 {
		p = append(p, fmt.Sprintf("social.goal.min_share_of_equal_bp is %d, outside 1..10000: at 0 a kingdom is carried by one lord and claimed by thirty, and over 10000 nobody could ever claim", g.MinShareOfEqualBP))
	}
	if len(g.Tiers) == 0 {
		p = append(p, "social.goal.tiers is empty, so a goal would have nothing at the end of it")
	}
	last := int64(0)
	for i, t := range g.Tiers {
		where := fmt.Sprintf("social.goal.tiers[%d]", i)
		if t.AtBP <= last {
			p = append(p, fmt.Sprintf("%s stands at %d bp, not past the one before (%d): the chests are a bar, and a bar only goes one way", where, t.AtBP, last))
		}
		last = t.AtBP
		if t.AtBP > 10000 {
			p = append(p, fmt.Sprintf("%s stands at %d bp, past the whole goal", where, t.AtBP))
		}
		grant(where+".grant", t.Grant, true)
	}
	if len(g.Tiers) > 0 && g.Tiers[len(g.Tiers)-1].AtBP != 10000 {
		p = append(p, "social.goal.tiers: the last chest must stand at 10000 bp -- the goal itself -- or finishing it pays nothing")
	}
	return p
}
