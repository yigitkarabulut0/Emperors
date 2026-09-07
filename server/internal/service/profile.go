package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

var (
	// ErrBadName marks a name that breaks the signup rules. The error carries
	// the rule that was broken, so the client can say what to fix.
	ErrBadName = errors.New("bad name")
	// ErrSameName is a rename to the name already held; paying for it would be
	// a hundred diamonds for nothing.
	ErrSameName = errors.New("that is already your name")
)

// badName is a NormalizeUsername failure wearing ErrBadName, so errors.Is finds
// it while Error() still reads as the rule ("username must start with a letter").
type badName struct{ reason error }

func (e badName) Error() string        { return e.reason.Error() }
func (e badName) Is(target error) bool { return target == ErrBadName }

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

// Rename buys the hero a new name for diamonds.
//
// The same rules as signup, for the same reason: the name is also the login
// identifier and the thing other players are shown when they are raided, so a
// homograph or a reserved word is no more acceptable bought than registered.
// The price is the live balance's store.rename_diamonds; the affordability
// check lives in the UPDATE's WHERE so a double tap cannot pay twice, and the
// password identity moves with the name so the player signs in with what they
// see on the plate.
func (d Deps) Rename(ctx context.Context, playerID uuid.UUID, name string, wantSeq int64) (*Snapshot, error) {
	canonical, display, err := auth.NormalizeUsername(name)
	if err != nil {
		return nil, badName{reason: err}
	}
	price := d.Config.Progression.Store.RenameDiamonds
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
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
		if p.Username == canonical && p.DisplayName == display {
			return ErrSameName
		}
		if _, err := q.RenamePlayer(ctx, sqlcdb.RenamePlayerParams{
			ID: playerID, Username: canonical, DisplayName: display,
			Diamonds: price, ActionSeq: wantSeq,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughDiamonds
			}
			if db.IsUniqueViolation(err, "players_username_lower_key") {
				return ErrUsernameTaken
			}
			return fmt.Errorf("rename player: %w", err)
		}
		if err := q.RenameIdentitySubject(ctx, sqlcdb.RenameIdentitySubjectParams{
			PlayerID: playerID, Kind: "password", Subject: canonical,
		}); err != nil {
			if db.IsUniqueViolation(err, "identities_kind_subject_key") {
				return ErrUsernameTaken
			}
			return fmt.Errorf("rename identity: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetState(ctx, playerID)
}

// RegisterDevice records where a player can be reached.
//
// Stored now, sent to later. The store is the half of push notifications that
// does not depend on Apple: a token can be collected, kept and re-pointed with
// no APNs key, no Push Notifications capability on the App ID, and no native
// plugin — and collecting it from day one means the first send does not have to
// wait for a round of installs.
func (d Deps) RegisterDevice(ctx context.Context, playerID uuid.UUID, token, platform string) error {
	if token == "" {
		return ErrInvalidAmount
	}
	if platform != "ios" && platform != "android" {
		return ErrNotFound
	}
	q := sqlcdb.New(d.Pool)
	if err := q.RegisterDevice(ctx, sqlcdb.RegisterDeviceParams{
		Token: token, PlayerID: playerID, Platform: platform,
	}); err != nil {
		return fmt.Errorf("register device: %w", err)
	}
	return nil
}
