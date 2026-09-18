package gameconfig

import (
	"fmt"
	"time"
)

// Buckets a festival may run a bonus in. Energy regeneration never (a timed
// regen is a mint); tax never (the storehouse fills from a cached rate, and a
// timed bonus cached into it outlives the festival).
var festivalBuckets = map[string]bool{
	BucketCollectIncome: true, BucketXP: true, BucketReputation: true, BucketShopDiscount: true,
}

// Buckets an hourly boost may run in: the timed lanes, and luck.
var hourlyBoostBuckets = map[string]bool{BucketCollectIncome: true, BucketXP: true, BucketLuck: true}

// validateLiveOps checks the realm's calendar. Every free grant is held to the
// reward rules as a letter is; the Charter's royal lane is held to the PAID
// rules, since money unlocks it.
func (b *Bundle) validateLiveOps() []string {
	var p []string
	lo := b.LiveOps
	grant := func(where string, g RewardBundle, paid bool) {
		if g.Empty() {
			p = append(p, fmt.Sprintf("%s grants nothing", where))
		}
		for _, problem := range b.CheckReward(g, paid) {
			p = append(p, fmt.Sprintf("%s: %s", where, problem))
		}
	}
	points := func(where string, src []PointSource) {
		if len(src) == 0 {
			p = append(p, fmt.Sprintf("%s: no deed earns points", where))
		}
		for _, s := range src {
			if !knownDeed(s.Deed) || s.Points <= 0 || s.Per <= 0 {
				p = append(p, fmt.Sprintf("%s: %q must be a counted deed with positive points and per", where, s.Deed))
			}
		}
	}
	ranks := func(where string, rr []RankReward) {
		for i, r := range rr {
			if r.Top < 1 || (i > 0 && r.Top <= rr[i-1].Top) {
				p = append(p, fmt.Sprintf("%s: places must rise from 1", where))
			}
			grant(fmt.Sprintf("%s top %d", where, r.Top), r.Grant, false)
		}
	}

	// --- the hourly event ---
	h := lo.Hourly
	if len(h.Table) < 2 {
		p = append(p, "liveops.hourly.table needs events besides \"none\" — the liveops section is missing or was not generated")
	}
	var bp int64
	ids := map[string]bool{}
	sawNone := false
	for _, e := range h.Table {
		if ids[e.ID] || e.ID == "" {
			p = append(p, fmt.Sprintf("liveops.hourly: %q needs a unique id", e.ID))
		}
		ids[e.ID] = true
		if e.BP <= 0 {
			p = append(p, fmt.Sprintf("liveops.hourly: %q has no chance — a published row that never comes is a lie", e.ID))
		}
		bp += e.BP
		if e.ID == HourlyNone {
			sawNone = true
			continue
		}
		where := "liveops.hourly " + e.ID
		if e.Name == "" || e.Blurb == "" || e.Icon == "" || e.Minutes < 1 || e.Minutes > 60 {
			p = append(p, fmt.Sprintf("%s: needs a name, a blurb, an icon and 1 to 60 minutes", where))
		}
		switch e.Effect.Kind {
		case HourlyBoost:
			if !hourlyBoostBuckets[e.Effect.Bucket] || e.Effect.BP <= 0 || e.Effect.BP > 20000 {
				p = append(p, fmt.Sprintf("%s: a boost is 1..20000 bp in collect_income_bp, xp_bp or luck_bp", where))
			}
		case HourlyRefillDiscount:
			if e.Effect.BP <= 0 || e.Effect.BP >= 10000 {
				p = append(p, fmt.Sprintf("%s: a refill discount is 1..9999 bp — a free refill is not a discount", where))
			}
		case HourlyFreeReroll:
			if e.Effect.Count < 1 {
				p = append(p, fmt.Sprintf("%s: free rerolls need a count", where))
			}
		case HourlyQuestMultiplier:
			if e.Effect.X < 2 || e.Effect.X > 5 {
				p = append(p, fmt.Sprintf("%s: a quest multiplier is 2 to 5", where))
			}
		case HourlyGift:
			grant(where, e.Effect.Grant, false)
		default:
			p = append(p, fmt.Sprintf("%s: unknown effect %q", where, e.Effect.Kind))
		}
	}
	if len(h.Table) > 0 && bp != 10000 {
		p = append(p, fmt.Sprintf("liveops.hourly.table sums to %d bp, not 10000 — the published odds must be the real ones", bp))
	}
	if len(h.Table) > 0 && !sawNone {
		p = append(p, "liveops.hourly.table has no \"none\" row: every hour would have an event")
	}

	// --- the festivals ---
	ev := lo.Events
	if len(ev.Templates) == 0 {
		p = append(p, "liveops.events.templates is empty")
	}
	if ev.AnnounceHours < 0 || ev.TopShown < 1 {
		p = append(p, "liveops.events: announce_hours must not be negative, top_shown at least 1")
	}
	tids := map[string]bool{}
	for _, t := range ev.Templates {
		where := "liveops.events " + t.ID
		if t.ID == "" || tids[t.ID] || t.Name == "" || t.Blurb == "" || t.Theme == "" {
			p = append(p, fmt.Sprintf("%s: needs a unique id, a name, a blurb and a theme", where))
		}
		tids[t.ID] = true
		if t.Days < 1 || t.Days > 14 {
			p = append(p, fmt.Sprintf("%s: runs 1 to 14 days", where))
		}
		if !festivalBuckets[t.Effect.Bucket] || t.Effect.BP <= 0 || t.Effect.BP > 10000 {
			p = append(p, fmt.Sprintf("%s: the bonus is 1..10000 bp in collect_income_bp, xp_bp, reputation_bp or shop_discount_bp", where))
		}
		points(where, t.Points)
		if t.DailyCap <= 0 {
			p = append(p, fmt.Sprintf("%s: a daily cap is what makes a festival won by coming back — it must be positive", where))
		}
		if len(t.Tasks) != 5 {
			p = append(p, fmt.Sprintf("%s: has %d tasks, not 5", where, len(t.Tasks)))
		}
		for _, k := range t.Tasks {
			if k.ID == "" || k.Name == "" || k.Short == "" || len([]rune(k.Short)) > 24 || !knownDeed(k.Deed) || k.Target <= 0 {
				p = append(p, fmt.Sprintf("%s task %q: needs a name, a short of 1..24, a counted deed and a target", where, k.ID))
			}
			if k.Icon != "quest_scroll" && k.Icon != "quest_bolt" && k.Icon != "quest_swords" {
				p = append(p, fmt.Sprintf("%s task %q: icon %q is not one of the three", where, k.ID, k.Icon))
			}
			grant(where+" task "+k.ID, k.Grant, false)
		}
		// Every milestone must be reachable within the days at the cap.
		reach := t.DailyCap * int64(t.Days)
		for i, m := range t.Milestones {
			if m.At <= 0 || (i > 0 && m.At <= t.Milestones[i-1].At) {
				p = append(p, fmt.Sprintf("%s: milestones rise, from above 0", where))
			}
			if m.At > reach {
				p = append(p, fmt.Sprintf("%s: a milestone at %d is past the %d the daily cap allows over %d days", where, m.At, reach, t.Days))
			}
			grant(fmt.Sprintf("%s milestone %d", where, m.At), m.Grant, false)
		}
		if len(t.Ranks) == 0 {
			p = append(p, fmt.Sprintf("%s: no places are paid", where))
		}
		ranks(where, t.Ranks)
	}

	// --- the season and its Royal Charter ---
	s := lo.Season
	if _, err := time.Parse("2006-01-02", s.Epoch); err != nil {
		p = append(p, "liveops.season.epoch must be a date, 2006-01-02")
	} else if e, _ := time.Parse("2006-01-02", s.Epoch); e.Weekday() != time.Monday {
		p = append(p, "liveops.season.epoch must be a Monday: seasons are whole weeks")
	}
	if s.Days < 7 || s.Days%7 != 0 {
		p = append(p, "liveops.season.days must be whole weeks, at least one")
	}
	if s.Tiers < 1 || len(s.Free) != s.Tiers || len(s.Royal) != s.Tiers {
		p = append(p, fmt.Sprintf("liveops.season: %d tiers need as many free and royal rewards (have %d and %d)", s.Tiers, len(s.Free), len(s.Royal)))
	}
	if s.PointsPerTier <= 0 || s.DailyCap <= 0 {
		p = append(p, "liveops.season: points_per_tier and daily_cap must be positive")
	}
	if s.DailyCap > 0 && s.PointsPerTier*int64(s.Tiers) > s.DailyCap*int64(s.Days) {
		p = append(p, "liveops.season: the last tier is past what the daily cap allows in a season")
	}
	points("liveops.season", s.Sources)
	if s.RoyalDiamonds <= 0 {
		p = append(p, "liveops.season.royal_diamonds must be positive")
	}
	if s.RoyalProduct != "" && b.Product(s.RoyalProduct) == nil {
		p = append(p, fmt.Sprintf("liveops.season: royal_product %q is not in commerce", s.RoyalProduct))
	}
	if s.KnightTier < 1 || s.KnightTier > s.Tiers {
		p = append(p, "liveops.season.knight_tier must be one of the tiers")
	}
	for i, g := range s.Free {
		grant(fmt.Sprintf("liveops.season free tier %d", i+1), g, false)
	}
	// The royal lane is bought: with money (the product) or with diamonds,
	// which money buys -- so it is held to the paid rules.
	for i, g := range s.Royal {
		grant(fmt.Sprintf("liveops.season royal tier %d", i+1), g, true)
	}

	// --- the boards and the nobility ---
	for li, list := range [][]BoardDef{lo.Ranks.Weekly, lo.Ranks.Season} {
		season := li == 1
		for _, bd := range list {
			where := "liveops.ranks " + bd.ID
			special := bd.Deed == BoardRenown || bd.Deed == BoardMightGain || bd.Deed == BoardArenaRating
			switch {
			case bd.ID == "" || bd.Name == "":
				p = append(p, fmt.Sprintf("%s: needs an id and a name", where))
			case special && !season:
				p = append(p, fmt.Sprintf("%s: %s is a season's count; a week's board counts a deed", where, bd.Deed))
			case !special && !knownDeed(bd.Deed):
				p = append(p, fmt.Sprintf("%s: counts %q, which nothing counts", where, bd.Deed))
			}
			ranks(where, bd.Rewards)
		}
	}
	for _, n := range lo.Ranks.Nobility {
		ways := 0
		for _, v := range []int{n.Top, n.TopPct, n.CharterTier} {
			if v > 0 {
				ways++
			}
		}
		if ways != 1 {
			p = append(p, fmt.Sprintf("liveops.ranks nobility %q: one of top, top_pct or charter_tier", n.ID))
		}
		for _, id := range []string{"frame_noble_" + n.ID, "title_noble_" + n.ID} {
			if b.Cosmetic(id) == nil {
				p = append(p, fmt.Sprintf("liveops.ranks nobility %q: cosmetics has no %q", n.ID, id))
			}
		}
	}

	// --- the deeds ---
	if len(lo.Achievements) == 0 {
		p = append(p, "liveops.achievements is empty")
	}
	if len(lo.AchievementTiers) != 4 {
		p = append(p, "liveops.achievement_tiers must pay four tiers")
	}
	for i, g := range lo.AchievementTiers {
		grant(fmt.Sprintf("liveops.achievement tier %d", i+1), g, false)
	}
	cats := map[string]bool{}
	for _, c := range AchievementCategories {
		cats[c] = true
	}
	aids := map[string]bool{}
	for _, a := range lo.Achievements {
		where := "liveops.achievements " + a.ID
		if a.ID == "" || aids[a.ID] || a.Name == "" || a.Blurb == "" {
			p = append(p, fmt.Sprintf("%s: needs a unique id, a name and a blurb", where))
		}
		aids[a.ID] = true
		if !cats[a.Category] {
			p = append(p, fmt.Sprintf("%s: unknown category %q", where, a.Category))
		}
		switch {
		case a.Deed != "" && a.Stat != "":
			p = append(p, fmt.Sprintf("%s: a deed or a stat, not both", where))
		case a.Deed != "" && !knownDeed(a.Deed):
			p = append(p, fmt.Sprintf("%s: counts %q, which nothing counts", where, a.Deed))
		case a.Stat != "" && a.Stat != StatLevel && a.Stat != StatMight && a.Stat != StatMasteries && a.Stat != StatCollection:
			p = append(p, fmt.Sprintf("%s: unknown stat %q", where, a.Stat))
		case a.Deed == "" && a.Stat == "":
			p = append(p, fmt.Sprintf("%s: counts nothing", where))
		}
		if len(a.Tiers) != 4 {
			p = append(p, fmt.Sprintf("%s: has %d tiers, not 4", where, len(a.Tiers)))
		}
		for i, t := range a.Tiers {
			if t <= 0 || (i > 0 && t <= a.Tiers[i-1]) {
				p = append(p, fmt.Sprintf("%s: tiers rise from above 0", where))
			}
		}
		if a.Stat == StatLevel && len(a.Tiers) == 4 && a.Tiers[3] > int64(b.Progression.LevelCap) {
			p = append(p, fmt.Sprintf("%s: a level past the cap can never be reached", where))
		}
		if c := b.Cosmetic(a.Title); c == nil || c.Kind != CosmeticTitle {
			p = append(p, fmt.Sprintf("%s: its title %q is not a title in cosmetics", where, a.Title))
		}
	}
	return p
}
