package admin

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

func pgInt8(v int64) pgtype.Int8 { return pgtype.Int8{Int64: v, Valid: true} }

// DiamondRow is one line of a player's diamond history.
type DiamondRow struct {
	ID           int64  `json:"id"`
	Delta        int64  `json:"delta"`
	Gross        int64  `json:"gross"`
	BalanceAfter int64  `json:"balance_after"`
	DebtAfter    int64  `json:"debt_after"`
	Reason       string `json:"reason"`
	Class        string `json:"class"`
	Ref          string `json:"ref"`
	At           string `json:"at"`
}

// DiamondLedger is a player's diamond history, newest first.
//
// Every grant, spend and refund is here -- the one place that can answer "where
// did this player's diamonds come from" to the diamond.
func (s *Service) DiamondLedger(ctx context.Context, playerID uuid.UUID, limit, offset int32) ([]DiamondRow, error) {
	rows, err := sqlcdb.New(s.Pool).ListDiamondLedger(ctx, sqlcdb.ListDiamondLedgerParams{
		PlayerID: playerID, Lim: limit, Off: offset,
	})
	if err != nil {
		return nil, err
	}
	out := make([]DiamondRow, 0, len(rows))
	for _, r := range rows {
		row := DiamondRow{
			ID: r.ID, Delta: r.Delta, Gross: r.Gross, BalanceAfter: r.BalanceAfter,
			DebtAfter: r.DebtAfter, Reason: r.Reason, Class: r.Class,
			At: r.CreatedAt.UTC().Format("2006-01-02 15:04"),
		}
		if r.RefID != nil {
			row.Ref = *r.RefID
		}
		out = append(out, row)
	}
	return out, nil
}

// DiamondFlow is diamonds created or destroyed for one reason over a window.
type DiamondFlow struct {
	Reason    string `json:"reason"`
	Class     string `json:"class"`
	Created   int64  `json:"created"`
	Destroyed int64  `json:"destroyed"`
	Entries   int64  `json:"entries"`
}

func (s *Service) diamondFlows(ctx context.Context, days int) ([]DiamondFlow, error) {
	rows, err := sqlcdb.New(s.Pool).DiamondFlows(ctx, int32(days))
	if err != nil {
		return nil, err
	}
	out := make([]DiamondFlow, 0, len(rows))
	for _, r := range rows {
		out = append(out, DiamondFlow{Reason: r.Reason, Class: r.Class,
			Created: r.Created, Destroyed: r.Destroyed, Entries: r.Entries})
	}
	return out, nil
}

// JobRun is one scheduled job and how its last run went.
type JobRun struct {
	Name      string `json:"name"`
	Period    string `json:"period"`
	ClaimedAt string `json:"claimed_at"`
	ClaimedBy string `json:"claimed_by"`
	Finished  string `json:"finished_at"`
	LastOK    string `json:"last_ok_at"`
	LastError string `json:"last_error"`
	Runs      int64  `json:"runs"`
	Failures  int64  `json:"failures"`
}

// JobRuns is every scheduled job the server has run.
func (s *Service) JobRuns(ctx context.Context) ([]JobRun, error) {
	rows, err := sqlcdb.New(s.Pool).ListJobRuns(ctx)
	if err != nil {
		return nil, err
	}
	stamp := func(t *time.Time) string {
		if t == nil {
			return ""
		}
		return t.UTC().Format("2006-01-02 15:04:05")
	}
	out := make([]JobRun, 0, len(rows))
	for _, r := range rows {
		j := JobRun{
			Name: r.JobName, Period: r.PeriodKey, ClaimedBy: r.ClaimedBy,
			ClaimedAt: r.ClaimedAt.UTC().Format("2006-01-02 15:04:05"),
			Finished:  stamp(r.FinishedAt), LastOK: stamp(r.LastOkAt),
			Runs: r.RunCount, Failures: r.FailCount,
		}
		if r.LastError != nil {
			j.LastError = *r.LastError
		}
		out = append(out, j)
	}
	return out, nil
}
