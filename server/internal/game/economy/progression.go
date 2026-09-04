package economy

import "github.com/yigitkarabulut0/emperors/server/internal/gameconfig"

// LevelUp is the outcome of awarding XP.
type LevelUp struct {
	Level        int
	XP           int64 // XP accumulated within the current level
	LevelsGained int
	StatPoints   int64 // points granted by those levels
	Refilled     bool  // whether energy should be topped up
}

// AwardXP adds experience and resolves any level-ups.
//
// XP is stored per-level (how far into the current level you are), not as a
// lifetime total. A lifetime total would mean a rebalance of the XP curve
// silently moving every player's level, which is exactly the kind of surprise a
// live game cannot afford.
//
// The loop handles multiple levels from one award — a level-1 player who claims
// a large milestone reward should jump several levels, not one.
func AwardXP(cfg *gameconfig.Bundle, level int, xpInLevel, gain int64, bonuses Bonuses) LevelUp {
	if gain > 0 {
		gain = ApplyBucket(gain, bonuses, BucketXPGain)
	} else {
		gain = 0
	}

	out := LevelUp{Level: level, XP: xpInLevel + gain}
	cap := cfg.Progression.LevelCap

	for out.Level < cap {
		need := cfg.XPToNext(out.Level)
		if need <= 0 || out.XP < need {
			break
		}
		out.XP -= need
		out.Level++
		out.LevelsGained++
		out.StatPoints += int64(cfg.Progression.StatPointsPerLevel)
	}

	if out.Level >= cap {
		// At the cap XP has nowhere to go. Park it at zero rather than letting an
		// unbounded number accumulate that the UI would render as a progress bar
		// filling forever.
		out.Level = cap
		out.XP = 0
	}

	out.Refilled = out.LevelsGained > 0 && cfg.Progression.Energy.LevelupRefill
	return out
}

// CollectResult is the outcome of one Collect action.
type CollectResult struct {
	Gold           int64
	XP             int64
	NewCollects    int64
	MilestoneHit   *gameconfig.Milestone // non-nil when this collect crossed a threshold
	MasteryBonusBP int64                 // the job's mastery bonus AFTER this collect
}

// Collect computes the reward for performing a job once.
//
// The mastery bonus applies to gold only, and it is the bonus for the count
// BEFORE this collect. Awarding the post-collect bonus on the crossing tap would
// make the milestone reward itself inconsistent with what the client predicted,
// and client prediction is what makes tapping feel instant.
func Collect(cfg *gameconfig.Bundle, job *gameconfig.Job, collectsBefore int64, bonuses Bonuses) CollectResult {
	masteryBefore := cfg.MilestoneBonusBP(collectsBefore)

	// The job's own mastery is additive within the collect-income bucket,
	// alongside upgrades and kingdom bonuses, and shares that bucket's cap.
	withMastery := bonuses
	withMastery.Add(BucketCollectIncome, masteryBefore)

	after := collectsBefore + 1
	res := CollectResult{
		Gold:           ApplyBucket(job.BaseGold, withMastery, BucketCollectIncome),
		XP:             job.BaseXP,
		NewCollects:    after,
		MasteryBonusBP: cfg.MilestoneBonusBP(after),
	}

	if res.MasteryBonusBP != masteryBefore {
		for i := range cfg.Jobs.Milestones {
			if cfg.Jobs.Milestones[i].Collects == after {
				res.MilestoneHit = &cfg.Jobs.Milestones[i]
				break
			}
		}
	}
	return res
}
