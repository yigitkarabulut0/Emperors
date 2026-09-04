package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

var (
	ErrNoStatPoints   = errors.New("not enough stat points")
	ErrNothingToSpend = errors.New("allocate at least one point")
)

// SpendStats allocates level-up points.
//
// Points are spent, never refunded. A respec would remove the weight from the
// choice, and the choice is the whole reason a soldierless player still has a
// build to make.
func (d Deps) SpendStats(ctx context.Context, playerID uuid.UUID, energy, attack, defense int32, wantSeq int64) (*Snapshot, error) {
	total := energy + attack + defense
	switch {
	case energy < 0 || attack < 0 || defense < 0:
		return nil, ErrNothingToSpend
	case total <= 0:
		return nil, ErrNothingToSpend
	}

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}

		if _, err := q.SpendStatPoints(ctx, sqlcdb.SpendStatPointsParams{
			ID: playerID, StatEnergy: energy, StatAttack: attack, StatDefense: defense,
			StatPointsUnspent: total, ActionSeq: wantSeq,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoStatPoints
			}
			return fmt.Errorf("spend stat points: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetState(ctx, playerID)
}
