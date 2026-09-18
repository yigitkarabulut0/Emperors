package gameconfig

import "fmt"

// What the kingdom's boss and its wars must be true of before they reach a
// kingdom (Wave 8).
//
// The two rules these exist for:
//
//   * a boss must be KILLABLE in its window and not by one lord alone. Its
//     health is the kingdom's own Might times a share, per blow the kingdom
//     has, so the share is the only number between "nobody ever kills it" and
//     "it falls to the first lord who logs in";
//   * a war must not be worth farming. A win over a lord who has lost every
//     banner pays a quarter, a loss still pays something, and the whole of it
//     is points -- validated here to carry no gold a raid could have taken.

func (b *Bundle) validateBoss() []string {
	var p []string
	c := b.Boss
	where := "boss"

	if c.Section == "" || !b.HasSection(c.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if c.CycleHours < 6 || c.CycleHours > 24*7 {
		p = append(p, fmt.Sprintf("%s.cycle_hours is %d, outside a quarter day and a week", where, c.CycleHours))
	}
	if c.HitsPerMember < 1 || c.HitsPerMember > 50 {
		p = append(p, fmt.Sprintf("%s.hits_per_member is %d, outside 1..50", where, c.HitsPerMember))
	}
	if c.RoundsPerHit < 1 || c.RoundsPerHit >= b.Soldiers.Combat.MaxRounds {
		p = append(p, fmt.Sprintf("%s.rounds_per_hit is %d and a whole battle is %d: a blow is a "+
			"fight CUT SHORT, or the beast is just another lord", where, c.RoundsPerHit,
			b.Soldiers.Combat.MaxRounds))
	}
	if c.EnergyBase <= 0 {
		p = append(p, where+".energy_base is zero: a blow that costs nothing is a blow worth farming")
	}
	if c.HPPerMightBP <= 0 {
		p = append(p, where+".hp_per_might_bp is zero, so the beast has no health at all")
	}
	// The share is the whole calibration: health is the kingdom's Might times
	// the blows each member has, times this. Under a twentieth and the beast
	// dies to the first lord who swings; over twice and nothing the kingdom can
	// raise in two days would put it down.
	if c.HPPerMightBP < 200 || c.HPPerMightBP > 20000 {
		p = append(p, fmt.Sprintf("%s.hp_per_might_bp is %d: a beast is between a twentieth and "+
			"twice the kingdom's own Might a blow, or it is not a siege", where, c.HPPerMightBP))
	}
	if c.HPGrowthBP <= 10000 {
		p = append(p, fmt.Sprintf("%s.hp_growth_bp is %d: a beast that does not harden is a beast "+
			"a kingdom kills for ever at the same price", where, c.HPGrowthBP))
	}
	if c.MaxLevel < 1 {
		p = append(p, where+".max_level is under one")
	}
	if c.ValourShareBP <= 0 || c.ValourShareBP > 10000 {
		p = append(p, fmt.Sprintf("%s.valour_share_bp is %d, outside 1..10000: valour is a share of "+
			"an EQUAL share", where, c.ValourShareBP))
	}
	if len(c.TopDiamonds) == 0 {
		p = append(p, where+".top_diamonds is empty: the damage list rewards nobody")
	}
	last := int64(1 << 62)
	for i, d := range c.TopDiamonds {
		if d <= 0 || d > last {
			p = append(p, fmt.Sprintf("%s.top_diamonds[%d] is %d, after %d: the list falls",
				where, i, d, last))
		}
		last = d
	}
	if c.TopTitle != "" && b.Cosmetic(c.TopTitle) == nil {
		p = append(p, fmt.Sprintf("%s.top_title %q is not a cosmetic", where, c.TopTitle))
	}
	if len(c.Rotation) < 2 {
		p = append(p, where+" has fewer than two beasts: a rotation of one is a wall")
	}
	seen := map[string]bool{}
	for i := range c.Rotation {
		r := &c.Rotation[i]
		rw := fmt.Sprintf("%s.rotation[%s]", where, r.ID)
		if r.ID == "" || r.Name == "" || r.Blurb == "" || r.Art == "" {
			p = append(p, rw+" needs an id, a name, a line and its own painting")
		}
		if seen[r.ID] {
			p = append(p, rw+" is in the rotation twice")
		}
		seen[r.ID] = true
		if r.AttackBP <= 0 || r.DefenseBP <= 0 {
			p = append(p, fmt.Sprintf("%s is not a fighter (attack %d bp, defence %d bp)",
				rw, r.AttackBP, r.DefenseBP))
		}
		// Both numbers are shares of an AVERAGE member's Might. A beast that
		// swung for more than four fifths of one would kill a lord of ordinary
		// strength before the blow was half over, and a kingdom's weakest lords
		// would never land anything at all.
		if r.AttackBP > 8000 {
			p = append(p, fmt.Sprintf("%s hits for %d bp of an average member's Might: an ordinary "+
				"lord would fall before the blow was half done", rw, r.AttackBP))
		}
		if r.DefenseBP > 8000 {
			p = append(p, fmt.Sprintf("%s shrugs off %d bp of an average member's Might: nothing "+
				"the kingdom swings would mark it", rw, r.DefenseBP))
		}
	}

	needs := map[string]bool{}
	for i, chest := range c.Chests {
		cw := fmt.Sprintf("%s.chests[%s]", where, chest.ID)
		if chest.ID == "" || chest.Name == "" {
			p = append(p, fmt.Sprintf("%s.chests[%d] needs an id and a name", where, i))
		}
		switch chest.Need {
		case BossNeedHit, BossNeedValour, BossNeedKill:
		default:
			p = append(p, fmt.Sprintf("%s asks for %q, which is not something a lord can do "+
				"(hit, valour, kill)", cw, chest.Need))
		}
		if needs[chest.Need] {
			p = append(p, cw+" asks for what another chest already asks for")
		}
		needs[chest.Need] = true
		if chest.Grant.Empty() {
			p = append(p, cw+" pays nothing")
		}
		// A boss chest is free content: money buys nothing here.
		for _, bad := range b.CheckReward(chest.Grant, false) {
			p = append(p, cw+": "+bad)
		}
	}
	if !needs[BossNeedHit] || !needs[BossNeedKill] {
		p = append(p, where+" has no chest for striking the beast, or none for killing it")
	}
	if c.ChestGrowthBP < 10000 {
		p = append(p, fmt.Sprintf("%s.chest_growth_bp is %d: a harder beast must pay more",
			where, c.ChestGrowthBP))
	}
	// And the hardest beast a kingdom can ever reach must still pay a letter
	// the post office will carry. A chest that grows a tenth every level is
	// over a hundred times its written size by level fifty, and a reward over
	// the limits is refused at the moment it is SENT -- which would be a job
	// failing in the night for the one kingdom that got that far.
	for i := range c.Chests {
		chest := &c.Chests[i]
		for _, bad := range b.CheckReward(c.GrownChest(chest, c.MaxLevel), false) {
			p = append(p, fmt.Sprintf("%s.chests[%s] at level %d (the hardest beast there is): %s",
				where, chest.ID, c.MaxLevel, bad))
		}
	}
	return p
}

func (b *Bundle) validateWar() []string {
	var p []string
	c := b.War
	where := "war"

	if c.Section == "" || !b.HasSection(c.Section) {
		p = append(p, where+".section names no gate in progression.sections")
	}
	if c.MatchWeekday < 0 || c.MatchWeekday > 6 {
		p = append(p, fmt.Sprintf("%s.match_weekday is %d, which is not a day", where, c.MatchWeekday))
	}
	if c.MatchHour < 0 || c.MatchHour > 23 {
		p = append(p, fmt.Sprintf("%s.match_hour is %d, which is not an hour", where, c.MatchHour))
	}
	if c.Days < 1 || c.Days > 6 {
		p = append(p, fmt.Sprintf("%s.days is %d: a war runs inside the week it was drawn in",
			where, c.Days))
	}
	if c.TopMembers < 1 {
		p = append(p, where+".top_members is under one, so a kingdom weighs nothing")
	}
	if c.MaxRatioBP <= 10000 {
		p = append(p, fmt.Sprintf("%s.max_ratio_bp is %d: a pair must be allowed to differ at all",
			where, c.MaxRatioBP))
	}
	if c.MaxRatioBP > 30000 {
		p = append(p, fmt.Sprintf("%s.max_ratio_bp is %d: three times is not a war", where, c.MaxRatioBP))
	}
	if c.MinMembers < 2 {
		p = append(p, where+".min_members is under two: a kingdom of one is a lord")
	}
	if c.AttacksPerDay < 1 || c.AttacksPerDay > 20 {
		p = append(p, fmt.Sprintf("%s.attacks_per_day is %d, outside 1..20", where, c.AttacksPerDay))
	}
	if c.Banners < 1 {
		p = append(p, where+".banners is under one: a defender must be able to be worn down")
	}
	if c.RoutBP <= 0 || c.RoutBP >= 10000 {
		p = append(p, fmt.Sprintf("%s.rout_bp is %d: beating a routed lord pays a SHARE, so a "+
			"kingdom cannot farm the one lord who cannot answer", where, c.RoutBP))
	}

	pt := c.Points
	if pt.WinBase <= 0 {
		p = append(p, where+".points.win_base is zero, so winning is worth nothing")
	}
	if pt.RatioMin <= 0 || pt.RatioMax <= pt.RatioMin {
		p = append(p, fmt.Sprintf("%s.points: the ratio is clamped to %d..%d bp, which is not a band",
			where, pt.RatioMin, pt.RatioMax))
	}
	if pt.RatioMax > 40000 {
		p = append(p, fmt.Sprintf("%s.points.ratio_max_bp is %d: one win on a giant would decide "+
			"the week", where, pt.RatioMax))
	}
	if pt.Loss < 0 || pt.Held <= 0 {
		p = append(p, where+".points: a loss may pay nothing but a defence held must pay something")
	}
	// The rule the war rests on: attacking must beat being attacked, or a
	// kingdom's best move is to sit still.
	if lowest := pt.WinBase * pt.RatioMin / 10000; lowest <= pt.Held {
		p = append(p, fmt.Sprintf("%s.points: the worst win pays %d and a held defence pays %d, so "+
			"a kingdom that never attacks does best", where, lowest, pt.Held))
	}
	if pt.Loss >= pt.WinBase*pt.RatioMin/10000 {
		p = append(p, fmt.Sprintf("%s.points: losing pays %d and the worst win %d", where,
			pt.Loss, pt.WinBase*pt.RatioMin/10000))
	}

	for name, purse := range map[string]WarPurse{"won": c.Won, "lost": c.Lost} {
		pw := where + "." + name
		if purse.Grant.Empty() {
			p = append(p, pw+" pays nothing at all")
		}
		for _, bad := range b.CheckReward(purse.Grant, false) {
			p = append(p, pw+": "+bad)
		}
		if purse.Reputation < 0 || purse.KingdomXP < 0 {
			p = append(p, pw+" takes reputation or experience away")
		}
	}
	if c.Won.Reputation <= c.Lost.Reputation || c.Won.KingdomXP <= c.Lost.KingdomXP {
		p = append(p, where+": losing a war is worth as much to a kingdom as winning it")
	}
	if c.WarlordTitle != "" && b.Cosmetic(c.WarlordTitle) == nil {
		p = append(p, fmt.Sprintf("%s.warlord_title %q is not a cosmetic", where, c.WarlordTitle))
	}
	return p
}
