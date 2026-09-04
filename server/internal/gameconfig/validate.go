package gameconfig

import (
	"fmt"
	"strings"
)

// Validate rejects a bundle that would break the game. It runs on the embedded
// seed at startup and, crucially, on every candidate the admin panel tries to
// publish — a bad publish must fail before it reaches players, not after.
func (b *Bundle) Validate() error {
	var p []string

	// --- jobs ---
	if len(b.Jobs.Jobs) == 0 {
		p = append(p, "no collect jobs defined")
	}
	seenOrder := map[int]bool{}
	for _, j := range b.Jobs.Jobs {
		switch {
		case j.ID == "":
			p = append(p, "a job has an empty id")
		case j.EnergyCost <= 0:
			p = append(p, fmt.Sprintf("job %q: energy_cost must be positive", j.ID))
		case j.BaseGold <= 0:
			p = append(p, fmt.Sprintf("job %q: base_gold must be positive", j.ID))
		case j.BaseXP <= 0:
			p = append(p, fmt.Sprintf("job %q: base_xp must be positive", j.ID))
		case j.UnlockLevel < 1:
			p = append(p, fmt.Sprintf("job %q: unlock_level must be at least 1", j.ID))
		case j.UnlockLevel > b.Progression.LevelCap:
			p = append(p, fmt.Sprintf("job %q: unlock_level %d exceeds the level cap %d — it would never unlock",
				j.ID, j.UnlockLevel, b.Progression.LevelCap))
		}
		if seenOrder[j.Order] {
			p = append(p, fmt.Sprintf("job %q: duplicate order %d", j.ID, j.Order))
		}
		seenOrder[j.Order] = true
	}

	// At least one job must be available at level 1, or a new player cannot act.
	if len(b.JobsForLevel(1)) == 0 {
		p = append(p, "no job unlocks at level 1 — a new player would have nothing to do")
	}

	// Gold per energy must not decrease as jobs unlock, or unlocking a job is a
	// downgrade and the ladder stops meaning anything.
	var prev float64
	var prevName string
	for _, j := range b.jobsAsc {
		gpe := float64(j.BaseGold) / float64(j.EnergyCost)
		if prev > 0 && gpe < prev {
			p = append(p, fmt.Sprintf(
				"job %q has worse gold/energy (%.2f) than the earlier %q (%.2f) — unlocking it would be a downgrade",
				j.ID, gpe, prevName, prev))
		}
		prev, prevName = gpe, j.ID
	}

	// --- milestones ---
	var lastBP int64 = -1
	for _, m := range b.Jobs.Milestones {
		if m.Collects <= 0 {
			p = append(p, "a milestone has a non-positive collect threshold")
		}
		if m.BonusBP <= lastBP {
			p = append(p, fmt.Sprintf("milestone at %d collects does not improve on the previous bonus", m.Collects))
		}
		lastBP = m.BonusBP
	}

	// --- progression ---
	if b.Progression.LevelCap < 1 {
		p = append(p, "level_cap must be at least 1")
	}
	for l := 1; l < b.Progression.LevelCap; l++ {
		if b.levelByIx[l].Level != l {
			p = append(p, fmt.Sprintf("progression is missing level %d", l))
			break
		}
		if b.levelByIx[l].XPToNext <= 0 {
			p = append(p, fmt.Sprintf("level %d has a non-positive xp_to_next — levelling would stall or loop", l))
			break
		}
	}

	// --- energy ---
	e := b.Progression.Energy
	if e.BaseMax <= 0 {
		p = append(p, "energy.base_max must be positive")
	}
	if e.RegenBaseSeconds <= 0 {
		p = append(p, "energy.regen_base_seconds must be positive — zero would regenerate infinite energy")
	}
	// The regen cap is the single ceiling on the whole gold supply. Without it,
	// stacked bonuses make daily income unbounded.
	if e.RegenBonusCapBP < 0 || e.RegenBonusCapBP > 20000 {
		p = append(p, "energy.regen_bonus_cap_bp must be between 0 and 20000 (+200%) — it bounds total gold supply")
	}

	// --- tiers ---
	if len(b.Tiers.Tiers) == 0 {
		p = append(p, "no tiers defined")
	}
	seenRank := map[int]bool{}
	var lastMult float64
	for _, t := range b.Tiers.Tiers {
		if seenRank[t.Rank] {
			p = append(p, fmt.Sprintf("tier %q: duplicate rank %d", t.ID, t.Rank))
		}
		seenRank[t.Rank] = true
		if t.StatMult < lastMult {
			p = append(p, fmt.Sprintf("tier %q is weaker than the tier below it", t.ID))
		}
		lastMult = t.StatMult
		if !strings.HasPrefix(t.Color, "#") || len(t.Color) != 7 {
			p = append(p, fmt.Sprintf("tier %q: color must be #rrggbb", t.ID))
		}
	}

	if len(p) > 0 {
		return fmt.Errorf("invalid game config:\n  - %s", strings.Join(p, "\n  - "))
	}
	return nil
}
