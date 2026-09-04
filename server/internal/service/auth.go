package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
)

// Tokens is what a successful authentication hands back.
type Tokens struct {
	AccessToken  string    `json:"access_token"`
	ExpiresAt    time.Time `json:"expires_at"`
	RefreshToken string    `json:"refresh_token"`
	PlayerID     string    `json:"player_id"`
}

// Register creates an account and signs it in.
func (d Deps) Register(ctx context.Context, username, password, userAgent string, tzOffsetMinutes int) (*Tokens, error) {
	canonical, display, err := auth.NormalizeUsername(username)
	if err != nil {
		return nil, err
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, err
	}
	if tzOffsetMinutes < -840 || tzOffsetMinutes > 840 {
		tzOffsetMinutes = 0
	}

	var out *Tokens
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		// A new player starts with a full bar so the first session is not spent
		// waiting for a meter to fill.
		startEnergy := economy.MaxEnergy(d.Config, 0, 0) * economy.MilliPerEnergy

		p, err := q.CreatePlayer(ctx, sqlcdb.CreatePlayerParams{
			Username:           canonical,
			DisplayName:        display,
			EnergyMilli:        startEnergy,
			ResetOffsetMinutes: int32(tzOffsetMinutes),
		})
		if err != nil {
			if db.IsUniqueViolation(err, "players_username_lower_key") {
				return ErrUsernameTaken
			}
			return fmt.Errorf("create player: %w", err)
		}

		if _, err := q.CreateIdentity(ctx, sqlcdb.CreateIdentityParams{
			PlayerID: p.ID, Kind: "password", Subject: canonical, SecretHash: &hash,
		}); err != nil {
			if db.IsUniqueViolation(err, "identities_kind_subject_key") {
				return ErrUsernameTaken
			}
			return fmt.Errorf("create identity: %w", err)
		}

		out, err = d.issueSession(ctx, q, p.ID, uuid.New(), userAgent)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Login verifies a password and starts a session.
func (d Deps) Login(ctx context.Context, username, password, userAgent string) (*Tokens, error) {
	canonical, _, err := auth.NormalizeUsername(username)
	if err != nil {
		// Do not leak which usernames are even well-formed.
		return nil, ErrBadCredentials
	}

	q := sqlcdb.New(d.Pool)
	ident, err := q.GetIdentityBySubject(ctx, sqlcdb.GetIdentityBySubjectParams{
		Kind: "password", Subject: canonical,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Spend comparable time on a miss so response timing does not reveal
			// whether the account exists.
			_ = auth.VerifyPassword(password, dummyHash)
			return nil, ErrBadCredentials
		}
		return nil, fmt.Errorf("load identity: %w", err)
	}
	if ident.SecretHash == nil {
		return nil, ErrBadCredentials
	}
	if err := auth.VerifyPassword(password, *ident.SecretHash); err != nil {
		return nil, ErrBadCredentials
	}

	p, err := q.GetPlayerByID(ctx, ident.PlayerID)
	if err != nil {
		return nil, fmt.Errorf("load player: %w", err)
	}
	if p.State == "banned" {
		return nil, ErrPlayerBanned
	}

	var out *Tokens
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		tq := sqlcdb.New(tx)
		_ = tq.MarkIdentityUsed(ctx, ident.ID)
		var err error
		out, err = d.issueSession(ctx, tq, p.ID, uuid.New(), userAgent)
		return err
	})
	return out, err
}

// Refresh rotates a refresh token.
//
// Rotation plus reuse detection: every refresh burns the presented token and
// issues a new one in the same family. If a token that has already been used is
// presented again, the only explanations are a stolen token or a replay, so the
// entire family is revoked — the thief and the victim are both logged out, which
// is the correct outcome because we cannot tell which is which.
func (d Deps) Refresh(ctx context.Context, refreshToken, userAgent string) (*Tokens, error) {
	hash := auth.HashRefreshToken(refreshToken)

	// Reuse detection has to COMMIT its revocation, but the request itself must
	// still fail. Returning an error from inside the transaction would roll the
	// revocation back and leave the stolen family alive — so the outcome is
	// carried out on this flag and the error is returned after the commit.
	var reuseDetected bool

	var out *Tokens
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		s, err := q.GetSessionByTokenHash(ctx, hash)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrSessionInvalid
			}
			return fmt.Errorf("load session: %w", err)
		}

		now := d.Now()
		switch {
		case s.RevokedAt != nil:
			return ErrSessionInvalid
		case s.UsedAt != nil:
			// Reuse of an already-rotated token means the token was captured: the
			// legitimate client already spent it. We cannot tell the thief from the
			// victim, so the whole rotation chain is burned and both must sign in
			// again. This write must survive, hence the flag rather than an error.
			reason := "refresh token reuse detected"
			if err := q.RevokeSessionFamily(ctx, sqlcdb.RevokeSessionFamilyParams{
				FamilyID: s.FamilyID, RevokedReason: &reason,
			}); err != nil {
				return fmt.Errorf("revoke family: %w", err)
			}
			reuseDetected = true
			return nil
		case now.After(s.ExpiresAt):
			return ErrSessionInvalid
		}

		if err := q.MarkSessionUsed(ctx, s.ID); err != nil {
			return fmt.Errorf("mark used: %w", err)
		}

		p, err := q.GetPlayerByID(ctx, s.PlayerID)
		if err != nil {
			return fmt.Errorf("load player: %w", err)
		}
		if p.State == "banned" {
			return ErrPlayerBanned
		}

		out, err = d.issueSession(ctx, q, s.PlayerID, s.FamilyID, userAgent)
		return err
	})
	if err != nil {
		return nil, err
	}
	if reuseDetected {
		return nil, ErrSessionInvalid
	}
	return out, nil
}

// issueSession stores a new refresh token and mints a matching access token.
func (d Deps) issueSession(ctx context.Context, q *sqlcdb.Queries, playerID, familyID uuid.UUID, userAgent string) (*Tokens, error) {
	refresh, refreshHash, err := auth.NewRefreshToken()
	if err != nil {
		return nil, err
	}
	var ua *string
	if userAgent != "" {
		if len(userAgent) > 200 {
			userAgent = userAgent[:200]
		}
		ua = &userAgent
	}

	s, err := q.CreateSession(ctx, sqlcdb.CreateSessionParams{
		PlayerID:  playerID,
		FamilyID:  familyID,
		TokenHash: refreshHash,
		ExpiresAt: d.Now().Add(auth.RefreshTokenTTL),
		UserAgent: ua,
	})
	if err != nil {
		return nil, fmt.Errorf("create session: %w", err)
	}

	access, exp, err := d.Signer.Mint(playerID.String(), s.ID.String())
	if err != nil {
		return nil, fmt.Errorf("mint access token: %w", err)
	}
	return &Tokens{
		AccessToken: access, ExpiresAt: exp,
		RefreshToken: refresh, PlayerID: playerID.String(),
	}, nil
}

// dummyHash is a real Argon2id hash of a random string, used to burn comparable
// CPU on an unknown username so login timing does not disclose account existence.
const dummyHash = "$argon2id$v=19$m=65536,t=2,p=4$c29tZXNhbHR2YWx1ZTAx$3P4kKQ0mVQ0KJc9nQ0Zz5x8Yq1rW2sT3uV4wX5yZ6a0"
