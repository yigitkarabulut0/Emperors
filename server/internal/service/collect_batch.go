package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

// BatchMax is the most collects one request may carry.
//
// A cap exists so a malicious or broken client cannot ask the server to hold a
// row lock while it applies ten thousand actions. 32 is comfortably more than a
// human can tap between two round trips.
const BatchMax = 32

// CollectBatchResult reports how far the batch got.
//
// AppliedThrough is the last action_seq that actually landed. The client uses it
// to drop exactly those actions from its queue: a batch that stops early -- ran
// out of energy, hit a locked job -- is a normal outcome, not an error, and the
// client must not resend what already applied.
type CollectBatchResult struct {
	Applied        int       `json:"applied"`
	AppliedThrough int64     `json:"applied_through"`
	GoldGained     int64     `json:"gold_gained"`
	XPGained       int64     `json:"xp_gained"`
	LevelsGained   int       `json:"levels_gained"`
	DiamondsGained int64     `json:"diamonds_gained,omitempty"`
	MilestoneHit   int64     `json:"milestone_hit,omitempty"`
	StoppedBecause string    `json:"stopped_because,omitempty"`
	Snapshot       *Snapshot `json:"snapshot"`
}

// CollectBatch performs a run of collects in a single transaction.
//
// Why this exists: action_seq is a per-player monotonic counter, so collects can
// never overlap -- the client had to send them strictly one at a time, and ten
// taps meant ten HTTP round trips and ten transactions. On a phone that is most
// of a second of visible lag and the reason the client had a "queued" counter to
// show for it.
//
// Applied in order, stopping at the first action that cannot be applied. Whatever
// ran before the stop is committed: those collects really did happen, and
// rolling them back would take gold the player already watched arrive.
func (d Deps) CollectBatch(ctx context.Context, playerID uuid.UUID, jobIDs []string, firstSeq int64) (*CollectBatchResult, error) {
	if len(jobIDs) == 0 {
		return nil, ErrNotFound
	}
	if len(jobIDs) > BatchMax {
		jobIDs = jobIDs[:BatchMax]
	}
	for _, id := range jobIDs {
		if d.Config.Job(id) == nil {
			return nil, ErrNotFound
		}
	}

	var res CollectBatchResult
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.State == "banned" {
			return ErrPlayerBanned
		}
		switch {
		case firstSeq <= p.ActionSeq:
			return ErrStaleAction
		case firstSeq > p.ActionSeq+1:
			return fmt.Errorf("%w: expected %d, got %d", ErrStaleAction, p.ActionSeq+1, firstSeq)
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}

		now := d.Now()
		energy, _, _ := settleEnergy(d.Config, p, eff, now)

		// The lifetime count per job is read once and advanced in memory, so the
		// mastery bonus is still computed from the count before each individual
		// collect without a database round trip for each one.
		counts := map[string]int64{}
		applied := map[string]int64{}

		level, xp := int(p.Level), p.Xp
		statPoints, diamonds := int64(p.StatPointsUnspent), int64(p.Diamonds)
		var goldGained, xpGained int64
		var levelsGained int

		for i, jobID := range jobIDs {
			job := d.Config.Job(jobID)
			if job.UnlockLevel > level {
				res.StoppedBecause = "job_locked"
				break
			}

			spent, ok := economy.Spend(energy, job.EnergyCost)
			if !ok {
				res.StoppedBecause = "not_enough_energy"
				break
			}

			if _, seen := counts[jobID]; !seen {
				prog, err := q.GetJobProgress(ctx, sqlcdb.GetJobProgressParams{
					PlayerID: playerID, JobID: jobID,
				})
				if err != nil && !errors.Is(err, pgx.ErrNoRows) {
					return fmt.Errorf("job progress: %w", err)
				}
				counts[jobID] = prog.Collects
			}

			reward := economy.Collect(d.Config, job, counts[jobID], eff.Bonuses)
			counts[jobID]++
			applied[jobID]++

			up := economy.AwardXP(d.Config, level, xp, reward.XP, eff.Bonuses)
			energy = spent
			// Levelling refills, and it must happen AFTER the spend or the
			// level-up silently refunds the collect that caused it.
			if up.Refilled {
				energy = economy.Refill(
					economy.MaxEnergy(d.Config, int64(up.Level), int64(p.StatEnergy), eff.MaxEnergyFlat), now)
			}

			level, xp = up.Level, up.XP
			statPoints, diamonds = up.StatPoints, up.Diamonds
			levelsGained += up.LevelsGained
			goldGained += reward.Gold
			xpGained += reward.XP
			if reward.MilestoneHit != nil {
				res.MilestoneHit = reward.MilestoneHit.Collects
			}

			res.Applied = i + 1
			res.AppliedThrough = firstSeq + int64(i)
		}

		if res.Applied == 0 {
			// Nothing could be applied at all. That is the same refusal the
			// single-action endpoint gives, so the client sees no new case.
			if res.StoppedBecause == "job_locked" {
				return ErrJobLocked
			}
			return ErrNotEnoughEnergy
		}

		for jobID, n := range applied {
			if _, err := q.BumpJobProgressBy(ctx, sqlcdb.BumpJobProgressByParams{
				PlayerID: playerID, JobID: jobID, N: n,
			}); err != nil {
				return fmt.Errorf("bump job progress: %w", err)
			}
		}

		if _, err := q.ApplyCollect(ctx, sqlcdb.ApplyCollectParams{
			ID:                playerID,
			EnergyMilli:       energy.Milli,
			EnergyUpdatedAt:   energy.UpdatedAt,
			Gold:              goldGained,
			Xp:                xp,
			Level:             int32(level),
			StatPointsUnspent: int32(statPoints),
			Diamonds:          diamonds,
			ActionSeq:         res.AppliedThrough,
		}); err != nil {
			return fmt.Errorf("apply collect batch: %w", err)
		}

		res.GoldGained = goldGained
		res.XPGained = xpGained
		res.LevelsGained = levelsGained
		res.DiamondsGained = diamonds - int64(p.Diamonds)
		return nil
	})
	if err != nil {
		return nil, err
	}

	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	res.Snapshot = snap
	return &res, nil
}
