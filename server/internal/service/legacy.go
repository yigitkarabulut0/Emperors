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

// ErrNotAtCap is a Legacy asked for before earning it.
var ErrNotAtCap = errors.New("only a lord at the height of their power may begin again")

// ErrLegacyMaxed is the tenth run already taken.
var ErrLegacyMaxed = errors.New("your line can carry no more")

// LegacyView is the Legacy offer, and where the player stands in it.
type LegacyView struct {
	Stacks    int   `json:"stacks"`
	MaxStacks int   `json:"max_stacks"`
	IncomeBP  int64 `json:"income_bp"`
	// What the next run would add, so the offer states its own price.
	NextBP    int64 `json:"next_bp"`
	Available bool  `json:"available"`
	AtLevel   int   `json:"at_level"`
	LevelCap  int   `json:"level_cap"`
}

// GetLegacy describes the offer.
func (d Deps) GetLegacy(ctx context.Context, playerID uuid.UUID) (*LegacyView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("legacy: %w", err)
	}
	c := d.Config.Progression.Legacy
	return &LegacyView{
		Stacks: int(p.Legacy), MaxStacks: c.MaxStacks,
		IncomeBP: int64(p.Legacy) * c.IncomeBPPerStack,
		NextBP:   c.IncomeBPPerStack,
		Available: int(p.Level) >= d.Config.Progression.LevelCap &&
			int(p.Legacy) < c.MaxStacks,
		AtLevel: int(p.Level), LevelCap: d.Config.Progression.LevelCap,
	}, nil
}

// BeginLegacy starts a new run.
//
// The guards live in the UPDATE's WHERE rather than in a check above it, so two
// taps cannot burn two runs and a client cannot ask for one it has not earned.
// A zero-row result means one of those two things, and the reason is worked out
// afterwards purely to say which.
func (d Deps) BeginLegacy(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*LegacyView, error) {
	c := d.Config.Progression.Legacy
	if c.MaxStacks <= 0 {
		return nil, ErrNotFound
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

		if _, err := q.BeginLegacy(ctx, sqlcdb.BeginLegacyParams{
			ID: playerID, ActionSeq: wantSeq,
			LevelCap: int32(d.Config.Progression.LevelCap), MaxStacks: int32(c.MaxStacks),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				if int(p.Legacy) >= c.MaxStacks {
					return ErrLegacyMaxed
				}
				return ErrNotAtCap
			}
			return fmt.Errorf("begin legacy: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetLegacy(ctx, playerID)
}
