package gameconfig

import (
	"fmt"
	"strings"
)

// Deeds a weekly task or a guide step may count. The game/deeds package owns
// the list; gameconfig cannot import game (the game packages import this one),
// so the names are repeated here and deeds_test.go holds the two together.
var KnownDeeds = []string{
	"collects", "energy", "xp", "raids", "raid_wins", "revenge_wins", "defenses_held", "gold_stolen",
	"buys", "shop_gold", "sells", "recruits", "rerolls", "upgrades", "holdings", "donated_gold",
	"stat_spends", "daily_quests", "daily_claims", "mail_claims", "carts_opened", "weekly_quests",
	"golden_hours", "arena_fights", "arena_wins", "bounties_placed", "bounties_claimed",
	"bounty_gold", "gifts_given", "aid_given",
	"campaign_stages", "campaign_firsts", "campaign_stars", "hunts_sent", "hunts_returned",
	"forges",
	"boss_hits", "boss_damage", "boss_kills", "war_attacks", "war_wins",
}

func knownDeed(d string) bool {
	for _, k := range KnownDeeds {
		if k == d {
			return true
		}
	}
	return false
}

// Guide targets the client can point at. A step naming anything else would
// leave the gauntlet pointing at nothing.
var guideTargets = map[string]bool{
	"collect.job0": true, "rail.court": true, "daily.claim": true, "court.chests": true,
	"shop.offer": true, "family.gear": true, "family.stats": true, "family.estates": true,
	"army.recruit": true, "attack.bandit": true,
}

var guideTabs = map[string]bool{
	"collect": true, "family": true, "inventory": true, "shop": true, "army": true,
	"attack": true, "kingdom": true, "court": true,
}

// validateRetention checks the daily loop. Every grant in it is free, and is
// held to the reward rules exactly as a letter is.
func (b *Bundle) validateRetention() []string {
	var p []string
	r := b.Retention
	grant := func(where string, g RewardBundle) {
		if g.Empty() {
			p = append(p, fmt.Sprintf("%s grants nothing", where))
		}
		for _, problem := range b.CheckReward(g, false) {
			p = append(p, fmt.Sprintf("%s: %s", where, problem))
		}
	}

	// --- the Tax Cart ---
	c := r.Cart
	if len(c.Odds) == 0 {
		p = append(p, "retention.cart.odds is empty — the retention section is missing or was not generated")
	}
	if c.IntervalSeconds < 600 || c.Cap < 1 || c.UnlockLevel < 1 || c.UnlockLevel > b.Progression.LevelCap {
		p = append(p, "retention.cart: interval_seconds must be at least ten minutes, cap at least 1, unlock_level a level")
	}
	var bp int64
	ids := map[string]bool{}
	for _, o := range c.Odds {
		if o.ID == "" || o.Name == "" || ids[o.ID] {
			p = append(p, fmt.Sprintf("retention.cart.odds: %q needs a unique id and a name", o.ID))
		}
		ids[o.ID] = true
		if o.BP <= 0 {
			p = append(p, fmt.Sprintf("retention.cart.odds: %q has no chance — a published row that never comes is a lie", o.ID))
		}
		bp += o.BP
		grant("retention.cart.odds "+o.ID, o.Grant)
	}
	if len(c.Odds) > 0 && bp != 10000 {
		p = append(p, fmt.Sprintf("retention.cart.odds sum to %d bp, not 10000 — the published odds must be the real ones", bp))
	}

	// --- the calendar ---
	cal := r.Calendar
	if len(cal.Squares) != 28 {
		p = append(p, fmt.Sprintf("retention.calendar has %d squares, not 28", len(cal.Squares)))
	}
	for i, s := range cal.Squares {
		day := i + 1
		where := fmt.Sprintf("retention.calendar day %d", day)
		grant(where, s.Grant)
		if s.Crown != (day%7 == 0) {
			p = append(p, fmt.Sprintf("%s: the crowns are days 7, 14, 21 and 28 exactly, as the page paints them", where))
		}
		if s.Crown != (s.Kind == SquareCrown) {
			p = append(p, fmt.Sprintf("%s: a crown square is kind %q, and only a crown square is", where, SquareCrown))
		}
		// The square's picture must be what it gives: a purse that paid
		// diamonds would be a picture that lies.
		g := s.Grant
		switch s.Kind {
		case SquareDiamonds:
			if g.Diamonds <= 0 || len(g.Tokens) > 0 || g.GoldWages > 0 || g.XPWages > 0 || len(g.Items) > 0 {
				p = append(p, fmt.Sprintf("%s: a diamonds square gives diamonds only", where))
			}
		case SquarePurse:
			if g.GoldWages <= 0 || g.Diamonds > 0 || len(g.Tokens) > 0 {
				p = append(p, fmt.Sprintf("%s: a purse square gives gold wages only", where))
			}
		case SquareScroll:
			if g.XPWages <= 0 || g.Diamonds > 0 || len(g.Tokens) > 0 {
				p = append(p, fmt.Sprintf("%s: a scroll square gives experience wages only", where))
			}
		case SquareFlask:
			if len(g.Tokens) != 1 || (g.Tokens["flask_small"] == 0 && g.Tokens["flask_large"] == 0) {
				p = append(p, fmt.Sprintf("%s: a flask square gives one kind of flask", where))
			}
		case SquareCart:
			if len(g.Tokens) != 1 || g.Tokens["cart"] == 0 {
				p = append(p, fmt.Sprintf("%s: a cart square gives cart writs", where))
			}
		case SquareCrown:
		default:
			p = append(p, fmt.Sprintf("%s: unknown kind %q", where, s.Kind))
		}
	}
	if cal.GraceDays < 0 || len(cal.RestoreDiamonds) != cal.GraceDays {
		p = append(p, "retention.calendar: restore_diamonds needs one price for each grace day")
	}
	for i, d := range cal.RestoreDiamonds {
		if d <= 0 || (i > 0 && d <= cal.RestoreDiamonds[i-1]) {
			p = append(p, "retention.calendar.restore_diamonds must be positive and rise with the days missed")
		}
	}
	if cal.PardonsPerCycle < 0 || cal.PardonsMax < cal.PardonsPerCycle {
		p = append(p, "retention.calendar: pardons_max must hold at least a cycle's pardons")
	}
	if cal.PardonsPerCycle > 0 && b.Token("pardon") == nil {
		p = append(p, "retention.calendar gives pardons, and rewards.tokens has no \"pardon\"")
	}

	// --- the week's quests ---
	w := r.Weekly
	tasks := append(append([]WeeklyTask(nil), w.Fixed...), w.Pool...)
	seen := map[string]bool{}
	for _, t := range tasks {
		where := "retention.weekly " + t.ID
		if t.ID == "" || seen[t.ID] {
			p = append(p, fmt.Sprintf("%s: needs a unique id", where))
		}
		seen[t.ID] = true
		if t.Name == "" || t.Short == "" || len([]rune(t.Short)) > 24 || t.Blurb == "" {
			p = append(p, fmt.Sprintf("%s: needs a name, a blurb and a short of 1 to 24 characters", where))
		}
		if t.Icon != "quest_scroll" && t.Icon != "quest_bolt" && t.Icon != "quest_swords" {
			p = append(p, fmt.Sprintf("%s: icon %q is not one of the painting's three", where, t.Icon))
		}
		if !knownDeed(t.Deed) {
			p = append(p, fmt.Sprintf("%s: counts %q, which nothing counts", where, t.Deed))
		}
		if t.Target <= 0 || t.Points <= 0 {
			p = append(p, fmt.Sprintf("%s: target and points must be positive", where))
		}
		grant(where, t.Grant)
	}
	if w.Draw < 0 || w.EligibleLevelFloor < 1 {
		p = append(p, "retention.weekly: draw must not be negative, eligible_level_floor at least 1")
	}
	firstWeek := 0
	for _, t := range w.Pool {
		if t.MinLevel <= w.EligibleLevelFloor {
			firstWeek++
		}
	}
	if firstWeek < w.Draw {
		p = append(p, fmt.Sprintf("retention.weekly: only %d pool tasks are open to a new lord, and a board draws %d", firstWeek, w.Draw))
	}
	// The last chest must be reachable on the leanest board a lord can draw.
	lean := int64(0)
	for _, t := range w.Fixed {
		lean += t.Points
	}
	if w.Draw > 0 && len(w.Pool) > 0 {
		least := w.Pool[0].Points
		for _, t := range w.Pool {
			if t.Points < least {
				least = t.Points
			}
		}
		lean += least * int64(w.Draw)
	}
	if len(w.Chests) == 0 {
		p = append(p, "retention.weekly.chests is empty")
	}
	for i, ch := range w.Chests {
		if ch.At <= 0 || (i > 0 && ch.At <= w.Chests[i-1].At) {
			p = append(p, "retention.weekly.chests must open at rising, positive points")
		}
		if ch.At > lean {
			p = append(p, fmt.Sprintf("retention.weekly: a chest at %d points is past the %d a full board can earn", ch.At, lean))
		}
		grant(fmt.Sprintf("retention.weekly chest %d", i+1), ch.Grant)
	}

	// --- the Golden Hour ---
	f := r.Frenzy
	if f.WindowSeconds <= 0 || f.FillPct <= 0 || f.FillPct > 100 || f.DurationSeconds <= 0 ||
		f.BonusBP <= 0 || f.CoverPct <= 0 || f.CoverPct > 100 || f.PerDay <= 0 || f.CooldownSeconds < 0 ||
		f.UnlockLevel < 1 {
		p = append(p, "retention.frenzy: every field must be positive, and the percentages at most 100")
	}

	// --- the Victory Road ---
	ms := r.Road.Milestones
	if len(ms) == 0 {
		p = append(p, "retention.road.milestones is empty")
	}
	if len(ms) > 31 {
		p = append(p, "retention.road: more than 31 milestones will not fit the claimed bitmask")
	}
	for i, m := range ms {
		where := fmt.Sprintf("retention.road level %d", m.Level)
		if m.Level < 2 || m.Level > b.Progression.LevelCap || (i > 0 && m.Level <= ms[i-1].Level) {
			p = append(p, fmt.Sprintf("%s: milestones rise, from level 2 to the cap", where))
		}
		grant(where, m.Grant)
	}

	// --- the guide ---
	g := r.Guide
	if len(g.Steps) == 0 {
		p = append(p, "retention.guide.steps is empty")
	}
	stepIDs := map[string]bool{}
	for i, s := range g.Steps {
		where := "retention.guide " + s.ID
		if s.ID == "" || stepIDs[s.ID] || s.Title == "" || s.Text == "" || s.Done == "" {
			p = append(p, fmt.Sprintf("%s: needs a unique id, a title, the steward's text and his done", where))
		}
		stepIDs[s.ID] = true
		if s.Tab != "" && !guideTabs[s.Tab] {
			p = append(p, fmt.Sprintf("%s: unknown tab %q", where, s.Tab))
		}
		if s.Target != "" && !guideTargets[s.Target] {
			p = append(p, fmt.Sprintf("%s: the client has no target %q", where, s.Target))
		}
		switch s.Kind {
		case GuideTap, GuideWorn, GuideFight:
		case GuideDeed:
			if !knownDeed(s.Deed) || s.Count <= 0 {
				p = append(p, fmt.Sprintf("%s: a deed step needs a counted deed and a count", where))
			}
		case GuideLevel:
			if s.Level < 2 || s.Level > b.Progression.LevelCap {
				p = append(p, fmt.Sprintf("%s: a level step needs a level to reach", where))
			}
		default:
			p = append(p, fmt.Sprintf("%s: unknown kind %q", where, s.Kind))
		}
		if s.Purse && s.Kind != GuideDeed {
			p = append(p, fmt.Sprintf("%s: only a deed step can have the steward's purse", where))
		}
		if i == len(g.Steps)-1 && s.Kind != GuideTap {
			p = append(p, "retention.guide: the last step is a farewell, tapped on")
		}
	}
	grant("retention.guide.finish", g.Finish)
	if g.PurseMax < 0 {
		p = append(p, "retention.guide.purse_max must not be negative")
	}
	bd := g.Bandit
	if bd.Name == "" || bd.Avatar == "" || bd.Seeds < 1 || bd.Level < 1 || bd.Attack <= 0 || bd.Defense < 0 ||
		bd.Speed <= 0 || bd.HP <= 0 {
		p = append(p, "retention.guide.bandit needs a name, an avatar, a level, seeds and a fighter's numbers")
	}
	grant("retention.guide.bandit", bd.Grant)

	// --- welcome back ---
	wb := r.Winback
	if wb.AwayDays < 1 || wb.LongAwayDays <= wb.AwayDays || wb.CooldownDays < 1 {
		p = append(p, "retention.winback: away_days at least 1, long_away_days past it, cooldown_days at least 1")
	}
	grant("retention.winback.grant", wb.Grant)
	grant("retention.winback.long_grant", wb.LongGrant)
	for _, t := range []string{wb.Title, wb.LongTitle} {
		if n := len([]rune(t)); n < 1 || n > 80 {
			p = append(p, "retention.winback: a letter's title is 1 to 80 characters")
		}
	}
	for _, body := range []string{wb.Body, wb.LongBody} {
		if strings.TrimSpace(body) == "" || len([]rune(body)) > 2000 {
			p = append(p, "retention.winback: a letter's body is 1 to 2000 characters")
		}
	}
	return p
}
