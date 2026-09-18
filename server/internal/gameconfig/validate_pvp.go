package gameconfig

import (
	"fmt"
	"time"
)

// Buckets a decree may run in: the two timed lanes and luck -- exactly the
// buckets an hourly boost may use, because a decree IS an hourly boost the
// realm's emperor fires. Tax is never one (the storehouse caches its rate, and
// a timed bonus cached into it outlives the decree); energy regeneration is
// never one (a timed regen is a mint).
var decreeBuckets = map[string]bool{BucketCollectIncome: true, BucketXP: true, BucketLuck: true}

// validatePvP checks Rekabet.
//
// Two of its rules deserve stating, because both are the kind that get
// "simplified" later:
//
// Nothing in this document is bought, so every grant is checked with paid=false
// -- the stricter of the two -- and an arena grant is checked again for
// experience, energy and boosts. The arena sits outside scripts/pace.py's
// budget BECAUSE this refuses to let it in; a comment would not have held.
//
// "A claim must not pay more than the bounty cost" cannot be written as
// arithmetic and should not be: a claim can only ever draw app.bounties.remaining,
// which is the escrow, and claim_cap_multiple x raidCap is a further ceiling on
// top, so the mint is structurally impossible in SQL. What is left to refuse is
// the two configurations that break the sink (fee_bp <= 0) and the drip
// (claim_cap_multiple at 0, or so large that one claim empties any bounty).
func (b *Bundle) validatePvP() []string {
	var p []string
	pv := b.PvP

	grant := func(where string, g RewardBundle, mustPay bool) {
		if mustPay && g.Empty() {
			p = append(p, fmt.Sprintf("%s grants nothing", where))
		}
		for _, problem := range b.CheckReward(g, false) {
			p = append(p, fmt.Sprintf("%s: %s", where, problem))
		}
	}
	// An arena grant may not level anybody. See the doc comment.
	arenaGrant := func(where string, g RewardBundle, mustPay bool) {
		grant(where, g, mustPay)
		if g.XP != 0 || g.XPWages != 0 {
			p = append(p, fmt.Sprintf("%s carries experience; the arena is deliberately outside scripts/pace.py's budget and a grant that levelled a lord would put it back inside without anyone measuring it", where))
		}
		if len(g.Boosts) > 0 {
			p = append(p, fmt.Sprintf("%s carries a boost; the arena pays looks and diamonds, not the economy", where))
		}
		for id := range g.Tokens {
			if t := b.Token(id); t != nil && t.EnergyPct > 0 {
				p = append(p, fmt.Sprintf("%s carries %q, which is energy; earned and bought energy alike is the day's three refills and nothing more", where, id))
			}
		}
	}
	section := func(where, id string) int {
		if id == "" {
			p = append(p, fmt.Sprintf("%s names no progression.sections gate", where))
			return 0
		}
		for _, s := range b.Progression.Sections {
			if s.ID == id {
				return s.Level
			}
		}
		p = append(p, fmt.Sprintf("%s names the gate %q, which progression.sections does not open", where, id))
		return 0
	}

	// --- the arena ---
	a := pv.Arena
	arenaAt := section("pvp.arena.section", a.Section)
	if fightAt := b.SectionLevel("fight"); arenaAt > 0 && arenaAt < fightAt {
		p = append(p, fmt.Sprintf("pvp.arena opens at level %d, before raiding does at %d", arenaAt, fightAt))
	}
	if a.TicketsPerDay < 1 || a.TicketsPerDay > 20 {
		p = append(p, fmt.Sprintf("pvp.arena.tickets_per_day is %d, outside 1..20", a.TicketsPerDay))
	}
	if a.RefreshesPerDay < 0 || a.RefreshesPerDay > 10 {
		p = append(p, fmt.Sprintf("pvp.arena.refreshes_per_day is %d, outside 0..10", a.RefreshesPerDay))
	}
	if a.OpponentsShown < 1 || a.OpponentsShown > 10 {
		p = append(p, fmt.Sprintf("pvp.arena.opponents_shown is %d, outside 1..10", a.OpponentsShown))
	}
	if a.FloorRating < 1 || a.StartRating <= a.FloorRating {
		p = append(p, "pvp.arena: the start rating must stand above a floor of at least 1, or every loss is free")
	}
	if a.MaxRating <= a.StartRating {
		p = append(p, "pvp.arena.max_rating must stand above the start rating")
	}
	if a.KFactor < 8 || a.KFactor > 64 {
		p = append(p, fmt.Sprintf("pvp.arena.k_factor is %d: below 8 a season cannot separate anyone, above 64 one fight decides a league", a.KFactor))
	}
	if a.DefenderKBP < 1 || a.DefenderKBP > 10000 {
		p = append(p, "pvp.arena.defender_k_bp is outside 1..10000: at 0 a defender never loses and the ladder only rises")
	}
	if a.ResetBP < 1 || a.ResetBP > 10000 {
		p = append(p, "pvp.arena.reset_bp is outside 1..10000: at 0 the ladder never resets and ossifies")
	}
	if a.BandRating < 1 || a.BandWiden < 1 || a.BandSteps < 1 || a.BandSteps > 6 {
		p = append(p, "pvp.arena: the matchmaking band needs a positive width, a positive widening and 1..6 steps")
	}
	if a.RepeatBlock < 0 {
		p = append(p, "pvp.arena.repeat_block cannot be negative")
	}
	if len(a.Leagues) < 2 {
		p = append(p, "pvp.arena.leagues needs at least two bands — the pvp section is missing or was not generated")
	}
	seenLeague := map[string]bool{}
	for i, l := range a.Leagues {
		where := fmt.Sprintf("pvp.arena.leagues[%d]", i)
		if l.ID == "" || seenLeague[l.ID] {
			p = append(p, fmt.Sprintf("%s has a missing or repeated id %q", where, l.ID))
		}
		seenLeague[l.ID] = true
		if l.Name == "" || l.Emblem == "" {
			p = append(p, fmt.Sprintf("%s (%s) needs a name and an emblem", where, l.ID))
		}
		if i == 0 && l.AtRating != 0 {
			p = append(p, "pvp.arena.leagues: the first league must open at 0, or a rating has no league at all")
		}
		if i > 0 && l.AtRating <= a.Leagues[i-1].AtRating {
			p = append(p, fmt.Sprintf("%s (%s) opens at %d, not above the league below it — an unreachable league", where, l.ID, l.AtRating))
		}
		if l.AtRating >= a.MaxRating {
			p = append(p, fmt.Sprintf("%s (%s) opens at %d, at or past the highest rating a lord may hold", where, l.ID, l.AtRating))
		}
		if l.TopN != 0 {
			if i != len(a.Leagues)-1 {
				p = append(p, fmt.Sprintf("%s (%s) asks for a place on the ladder; only the last league may, or the scarce league is not the top one", where, l.ID))
			}
			if l.TopN < 1 {
				p = append(p, fmt.Sprintf("%s (%s) asks for top %d", where, l.ID, l.TopN))
			}
		}
		if l.Cosmetic != "" {
			if c := b.Cosmetic(l.Cosmetic); c == nil || c.Kind != CosmeticFrame {
				p = append(p, fmt.Sprintf("%s (%s) wears %q, which is not a frame in the catalogue", where, l.ID, l.Cosmetic))
			}
		}
	}
	arenaGrant("pvp.arena.first_win", a.FirstWin, true)
	arenaGrant("pvp.arena.win_grant", a.WinGrant, false)
	arenaGrant("pvp.arena.loss_grant", a.LossGrant, false)
	top := 0
	if n := len(a.Leagues); n > 0 {
		top = a.Leagues[n-1].AtRating
	}
	for i, m := range a.Milestones {
		where := fmt.Sprintf("pvp.arena.milestones[%d]", i)
		if m.Rating <= a.StartRating {
			p = append(p, fmt.Sprintf("%s opens at %d, at or below the rating every lord starts on — it would pay for turning up", where, m.Rating))
		}
		if i > 0 && m.Rating <= a.Milestones[i-1].Rating {
			p = append(p, fmt.Sprintf("%s does not stand above the milestone below it", where))
		}
		if m.Rating > top+400 {
			p = append(p, fmt.Sprintf("%s opens at %d, out of reach of the top league at %d", where, m.Rating, top))
		}
		arenaGrant(where, m.Grant, true)
	}
	if a.Bot.Name == "" || !b.HasAvatar(a.Bot.Avatar) {
		p = append(p, "pvp.arena.bot needs a name and a portrait a lord could wear")
	}
	if a.Bot.MightBP < 1 || a.Bot.MightBP > 10000 {
		p = append(p, "pvp.arena.bot.might_bp is outside 1..10000: a hired champion stronger than the lord it is offered to is a loss dressed as a fight")
	}
	if a.Bot.RatingBP < 1 || a.Bot.RatingBP > 10000 {
		p = append(p, "pvp.arena.bot.rating_bp is outside 1..10000")
	}

	// --- the bounty board ---
	bo := pv.Bounty
	bountyAt := section("pvp.bounty.section", bo.Section)
	if arenaAt > 0 && bountyAt > 0 && bountyAt < arenaAt {
		p = append(p, fmt.Sprintf("pvp.bounty opens at level %d, before the arena does at %d", bountyAt, arenaAt))
	}
	if bo.MinAmount < 1 {
		p = append(p, "pvp.bounty.min_amount is zero, which prices the action at the floor rather than refusing to load")
	}
	if bo.FeeBP <= 0 {
		p = append(p, "pvp.bounty.fee_bp is zero: a bounty with no fee is a way to move gold between two accounts for nothing, and the burn is the only thing that makes this a sink")
	}
	if bo.FeeBP >= 10000 {
		p = append(p, "pvp.bounty.fee_bp is at or over 100%, which makes the sink the feature")
	}
	if bo.FeeBP > 0 && bo.MinAmount*bo.FeeBP/10000 < 1 {
		p = append(p, "pvp.bounty: the smallest bounty's fee rounds to nothing, which is no fee")
	}
	if len(bo.Plates) == 0 {
		p = append(p, "pvp.bounty.plates is empty — the board would offer nothing")
	}
	seenPlate := map[string]bool{}
	for i, pl := range bo.Plates {
		where := fmt.Sprintf("pvp.bounty.plates[%d]", i)
		if pl.ID == "" || seenPlate[pl.ID] {
			p = append(p, fmt.Sprintf("%s has a missing or repeated id %q", where, pl.ID))
		}
		seenPlate[pl.ID] = true
		if pl.Amount < bo.MinAmount {
			p = append(p, fmt.Sprintf("%s offers %d, below the minimum of %d", where, pl.Amount, bo.MinAmount))
		}
		if i == 0 && pl.Amount != bo.MinAmount {
			p = append(p, "pvp.bounty.plates: the first plate must be the minimum, or the minimum is not one")
		}
		if i > 0 && pl.Amount <= bo.Plates[i-1].Amount {
			p = append(p, fmt.Sprintf("%s does not stand above the plate below it", where))
		}
		if l := b.Rewards.Limits.MaxGold; l > 0 && pl.Amount > l {
			p = append(p, fmt.Sprintf("%s offers %d, more gold than a refund letter may carry (%d) — a bounty that cannot expire", where, pl.Amount, l))
		}
	}
	if bo.Hours < 1 || bo.Hours > 168 {
		p = append(p, fmt.Sprintf("pvp.bounty.hours is %d, outside 1..168", bo.Hours))
	}
	if bo.ClaimCapMultiple < 1 {
		p = append(p, "pvp.bounty.claim_cap_multiple is zero: nobody could ever claim")
	}
	if bo.ClaimCapMultiple > 10 {
		p = append(p, "pvp.bounty.claim_cap_multiple is over ten: one claim would empty any bounty, and the days it stands would be theatre")
	}
	for _, c := range []struct {
		name string
		v    int
	}{
		{"places_per_day", bo.PlacesPerDay}, {"open_per_target", bo.OpenPerTarget},
		{"claims_per_target", bo.ClaimsPerTarget}, {"cooldown_minutes", bo.CooldownMinutes},
		{"pair_claims_per_week", bo.PairClaimsPerWeek}, {"min_account_hours", bo.MinAccountHours},
	} {
		if c.v < 1 {
			p = append(p, fmt.Sprintf("pvp.bounty.%s is zero, which is the leash removed", c.name))
		}
	}
	if bo.MaxLevelsAbove < 0 {
		p = append(p, "pvp.bounty.max_levels_above cannot be negative")
	}
	if bo.MinTargetMightBP < 1 || bo.MinTargetMightBP > 10000 {
		p = append(p, "pvp.bounty.min_target_might_bp is outside 1..10000")
	}

	// --- the throne ---
	th := pv.Throne
	if t, err := time.Parse("2006-01-02", th.Epoch); err != nil {
		p = append(p, fmt.Sprintf("pvp.throne.epoch %q is not a date", th.Epoch))
	} else if t.Weekday() != time.Monday {
		p = append(p, fmt.Sprintf("pvp.throne.epoch %s is a %s; a reign is a whole UTC week and must begin on a Monday", th.Epoch, t.Weekday()))
	}
	if th.MinMembers < 2 {
		p = append(p, "pvp.throne.min_members is under two: a kingdom of one is a lord")
	}
	if th.ReignDays != 7 {
		p = append(p, "pvp.throne.reign_days must be 7: settlement is Monday to Monday, and anything else leaves a gap or two emperors at once")
	}
	if th.Measure != ThroneWeekGain && th.Measure != ThroneTotal {
		p = append(p, fmt.Sprintf("pvp.throne.measure is %q, not %q or %q", th.Measure, ThroneWeekGain, ThroneTotal))
	}
	switch th.DecreeScope {
	case ThroneScopeRealm, ThroneScopeKingdom, ThroneScopeEmperor:
	default:
		p = append(p, fmt.Sprintf("pvp.throne.decree_scope is %q, not realm, kingdom or emperor", th.DecreeScope))
	}
	if th.DecreesPerReign < 1 {
		p = append(p, "pvp.throne.decrees_per_reign is zero: a throne with no edict is a title")
	}
	if len(th.Decrees) == 0 {
		p = append(p, "pvp.throne.decrees is empty")
	}
	seenDecree := map[string]bool{}
	for i, d := range th.Decrees {
		where := fmt.Sprintf("pvp.throne.decrees[%d]", i)
		if d.ID == "" || seenDecree[d.ID] {
			p = append(p, fmt.Sprintf("%s has a missing or repeated id %q", where, d.ID))
		}
		seenDecree[d.ID] = true
		if d.Name == "" || d.Blurb == "" || d.Icon == "" {
			p = append(p, fmt.Sprintf("%s (%s) needs a name, a line and an icon", where, d.ID))
		}
		if !decreeBuckets[d.Bucket] {
			p = append(p, fmt.Sprintf("%s (%s) runs in %q; a decree is a timed bonus and may only use %s, %s or %s — never %s (the storehouse caches its rate) and never %s",
				where, d.ID, d.Bucket, BucketCollectIncome, BucketXP, BucketLuck, BucketTaxIncome, BucketEnergyRegen))
		}
		if d.BP < 1 || d.BP > 10000 {
			p = append(p, fmt.Sprintf("%s (%s) is %d bp, outside 1..10000", where, d.ID, d.BP))
		}
		if d.Minutes < 1 || d.Minutes > 240 {
			p = append(p, fmt.Sprintf("%s (%s) runs %d minutes, outside 1..240: an edict that outlasts the hour it is felt in stops being an event", where, d.ID, d.Minutes))
		}
	}
	for _, c := range []struct{ what, id, kind string }{
		{"pvp.throne.emperor_frame", th.EmperorFrame, CosmeticFrame},
		{"pvp.throne.emperor_title", th.EmperorTitle, CosmeticTitle},
		{"pvp.throne.court_title", th.CourtTitle, CosmeticTitle},
	} {
		if c.id == "" {
			p = append(p, fmt.Sprintf("%s names no cosmetic", c.what))
			continue
		}
		if got := b.Cosmetic(c.id); got == nil || got.Kind != c.kind {
			p = append(p, fmt.Sprintf("%s is %q, which is not a %s in the catalogue", c.what, c.id, c.kind))
		}
	}
	grant("pvp.throne.emperor_grant", th.EmperorGrant, true)
	grant("pvp.throne.court_grant", th.CourtGrant, false)
	if th.PastReignsShown < 1 {
		p = append(p, "pvp.throne.past_reigns_shown is zero")
	}
	return p
}
