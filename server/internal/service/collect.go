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

// CollectResult is what one Collect returns. It carries the deltas as well as
// the new snapshot so the client can reconcile its optimistic prediction and
// animate the difference, rather than snapping numbers.
type CollectResult struct {
	GoldGained     int64 `json:"gold_gained"`
	XPGained       int64 `json:"xp_gained"`
	LevelsGained   int   `json:"levels_gained"`
	DiamondsGained int64 `json:"diamonds_gained,omitempty"`
	MilestoneHit   int64 `json:"milestone_hit,omitempty"`
	// Which job crossed it. Without this the client knows a milestone happened
	// but not what it was for, and a batch can span more than one job.
	MilestoneJob string    `json:"milestone_job,omitempty"`
	Snapshot     *Snapshot `json:"snapshot"`
}

// Collect performs one job.
//
// Everything is server-side: the client sends only which job, never a payout.
//
// Idempotency uses a per-player monotonic sequence. The client sends the
// sequence number it expects this action to produce. A retry on a flaky mobile
// network replays the same number, which the server recognises as already
// applied and answers with current state instead of spending energy twice. A
// number further ahead means the client missed a response and is out of sync, so
// it is refused rather than guessed at.
func (d Deps) Collect(ctx context.Context, playerID uuid.UUID, jobID string, wantSeq int64) (*CollectResult, error) {
	job := d.Config.Job(jobID)
	if job == nil {
		return nil, ErrNotFound
	}

	var res CollectResult
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		// FOR UPDATE. Without it two concurrent taps both read the same energy
		// and both spend it, and the player collects twice for one point.
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
		case wantSeq <= p.ActionSeq:
			return ErrStaleAction
		case wantSeq > p.ActionSeq+1:
			return fmt.Errorf("%w: expected %d, got %d", ErrStaleAction, p.ActionSeq+1, wantSeq)
		}

		if job.UnlockLevel > int(p.Level) {
			return ErrJobLocked
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}

		now := d.Now()
		settled, maxEnergy, period := settleEnergy(d.Config, p, eff, now)

		spent, ok := economy.Spend(settled, job.EnergyCost)
		if !ok {
			return ErrNotEnoughEnergy
		}

		progress, err := q.BumpJobProgress(ctx, sqlcdb.BumpJobProgressParams{
			PlayerID: playerID, JobID: jobID,
		})
		if err != nil {
			return fmt.Errorf("bump job progress: %w", err)
		}
		collectsBefore := progress.Collects - 1

		reward := economy.Collect(d.Config, job, collectsBefore, eff.Bonuses)
		up := economy.AwardXP(d.Config, int(p.Level), p.Xp, reward.XP, eff.Bonuses)

		// Levelling refills energy, which must happen AFTER the spend or the
		// level-up would silently refund the cost of the collect that caused it.
		final := spent
		if up.Refilled {
			final = economy.Refill(economy.MaxEnergy(d.Config, int64(p.Level), int64(p.StatEnergy), eff.MaxEnergyFlat), now)
		}

		after, err := q.ApplyCollect(ctx, sqlcdb.ApplyCollectParams{
			ID:                playerID,
			EnergyMilli:       final.Milli,
			EnergyUpdatedAt:   final.UpdatedAt,
			Gold:              reward.Gold,
			Xp:                up.XP,
			Level:             int32(up.Level),
			StatPointsUnspent: int32(up.StatPoints),
			Diamonds:          up.Diamonds,
			ActionSeq:         wantSeq,
		})
		if err != nil {
			return fmt.Errorf("apply collect: %w", err)
		}

		// The biggest faucet in the game, and it was never in the ledger -- so
		// the admin dashboard's "sinks absorb N% of what faucets create", the one
		// number that says whether the currency is inflating, was computed
		// without the source of most of the currency.
		if reward.Gold > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: reward.Gold, BalanceAfter: after.Gold,
				Reason: "collect", RefID: nil,
			}); err != nil {
				return fmt.Errorf("record collect: %w", err)
			}
		}

		res = CollectResult{
			GoldGained: reward.Gold,
			// The experience actually awarded, not the job's raw figure.
			// AwardXP applies the experience bucket internally, so reporting
			// reward.XP told a player "+2 xp" while their bar moved by 4 during
			// a double-experience event.
			XPGained:       economy.ApplyBucket(reward.XP, eff.Bonuses, economy.BucketXPGain),
			LevelsGained:   up.LevelsGained,
			DiamondsGained: up.Diamonds,
		}
		if reward.MilestoneHit != nil {
			res.MilestoneHit = reward.MilestoneHit.Collects
			res.MilestoneJob = job.ID
		}
		_ = maxEnergy
		_ = period
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Read the snapshot after commit so the client gets exactly what a fresh
	// GET /v1/state would return — no chance of the two disagreeing.
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	res.Snapshot = snap
	return &res, nil
}
