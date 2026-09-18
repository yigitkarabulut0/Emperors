package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// levelRef names the levels a level-up grant was for, as the diamond ledger's
// reference: "L12-13". Empty when no level was crossed.
func levelRef(from int32, to int) string {
	if int(from) >= to {
		return ""
	}
	return fmt.Sprintf("L%d-%d", from, to)
}

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
	MilestoneJob string `json:"milestone_job,omitempty"`
	// The part of GoldGained the Golden Hour added, and whether this collect
	// lit it (retention.frenzy). The client shows the burst; it never predicts.
	FrenzyGold    int64     `json:"frenzy_gold"`
	FrenzyStarted bool      `json:"frenzy_started"`
	Snapshot      *Snapshot `json:"snapshot"`
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

		// The Golden Hour: this collect fills its meter, or is paid its bonus in
		// the timed lane of the collect bucket -- the gold it added is the
		// difference, both sides through the one formula.
		golden := d.newFrenzyRun(p, now)
		bonuses, covered := d.frenzyBonuses(golden, eff.Bonuses, job.EnergyCost, maxEnergy, int(p.Level), now)
		reward := economy.Collect(d.Config, job, collectsBefore, bonuses)
		if covered {
			golden.gold = reward.Gold - economy.Collect(d.Config, job, collectsBefore, eff.Bonuses).Gold
		}
		up := economy.AwardXP(d.Config, int(p.Level), p.Xp, reward.XP, eff.Bonuses)

		// Levelling refills energy, which must happen AFTER the spend or the
		// level-up would silently refund the cost of the collect that caused it.
		final := spent
		if up.Refilled {
			final = economy.Refill(levelUpMax(d.Config, p, up, eff), now)
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
		if err := recordCollectGold(ctx, q, playerID, reward.Gold, golden.gold, after.Gold); err != nil {
			return err
		}
		if err := golden.save(ctx, q, p); err != nil {
			return err
		}
		if err := ledger.Diamonds(ctx, q, p, after, up.Diamonds, ledger.LevelUp,
			levelRef(p.Level, up.Level)); err != nil {
			return err
		}

		// A single collect is a collect. Only the batch route used to count
		// toward today's tasks, so a player whose taps went one at a time -- a
		// slow network, the first tap after a refresh -- saw "Collect 20 times"
		// stall behind collects that really happened.
		done := deeds.Deeds{
			deeds.Collects: 1, deeds.Energy: job.EnergyCost,
			deeds.XP: economy.ApplyBucket(reward.XP, eff.Bonuses, economy.BucketXPGain),
		}
		if golden.started {
			done[deeds.GoldenHours] = 1
		}
		d.recordDeeds(ctx, tx, p, done)

		res = CollectResult{
			GoldGained: reward.Gold,
			// The experience actually awarded, not the job's raw figure.
			// AwardXP applies the experience bucket internally, so reporting
			// reward.XP told a player "+2 xp" while their bar moved by 4 during
			// a double-experience event.
			XPGained:       economy.ApplyBucket(reward.XP, eff.Bonuses, economy.BucketXPGain),
			LevelsGained:   up.LevelsGained,
			DiamondsGained: up.Diamonds,
			FrenzyGold:     golden.gold,
			FrenzyStarted:  golden.started,
		}
		if reward.MilestoneHit != nil {
			res.MilestoneHit = reward.MilestoneHit.Collects
			res.MilestoneJob = job.ID
		}
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

// recordCollectGold writes a run of collects' gold to the ledger: the Golden
// Hour's share on its own row, so the economy's faucets say what it added.
func recordCollectGold(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, gold, golden, balance int64) error {
	if base := gold - golden; base > 0 {
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: base, BalanceAfter: balance - golden, Reason: "collect",
		}); err != nil {
			return fmt.Errorf("record collect: %w", err)
		}
	}
	if golden > 0 {
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: golden, BalanceAfter: balance, Reason: "golden_hour",
		}); err != nil {
			return fmt.Errorf("record the golden hour: %w", err)
		}
	}
	return nil
}
