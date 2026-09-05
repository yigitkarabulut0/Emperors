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

// AvatarOption is one pickable portrait.
type AvatarOption struct {
	ID       string `json:"id"`
	Selected bool   `json:"selected"`
}

// Avatars lists what this player may choose from, marking the current pick.
//
// The list comes from the live balance document rather than from code, so
// portraits can be added without a client or server deploy.
func (d Deps) Avatars(ctx context.Context, playerID uuid.UUID) ([]AvatarOption, error) {
	p, err := sqlcdb.New(d.Pool).GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("get player: %w", err)
	}
	ids := d.Config.Progression.Avatars
	out := make([]AvatarOption, 0, len(ids))
	for _, id := range ids {
		out = append(out, AvatarOption{ID: id, Selected: id == p.Avatar})
	}
	return out, nil
}

// SetAvatar changes the player's portrait.
func (d Deps) SetAvatar(ctx context.Context, playerID uuid.UUID, avatar string, wantSeq int64) (*Snapshot, error) {
	if !d.Config.HasAvatar(avatar) {
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
		if _, err := q.SetAvatar(ctx, sqlcdb.SetAvatarParams{
			ID: playerID, Avatar: avatar, ActionSeq: wantSeq,
		}); err != nil {
			return fmt.Errorf("set avatar: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetState(ctx, playerID)
}
