// Package service holds the use-cases. Each one owns a transaction, reads
// state, calls the pure code in internal/game, writes the result, and returns.
//
// Handlers stay thin; game rules never appear here, only orchestration.
package service

import (
	"errors"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Errors the HTTP layer maps to status codes. Services return these rather than
// status codes so the domain stays transport-agnostic.
var (
	ErrUsernameTaken   = errors.New("username is taken")
	ErrBadCredentials  = errors.New("wrong username or password")
	ErrPlayerBanned    = errors.New("account is banned")
	ErrNotFound        = errors.New("not found")
	ErrJobLocked       = errors.New("job is not unlocked yet")
	ErrNotEnoughEnergy = errors.New("not enough energy")
	ErrStaleAction     = errors.New("action already applied")
	ErrSessionInvalid  = errors.New("session is invalid")
)

// Clock is injected so tests can control time and so the economy stays
// deterministic. Nothing in service or game calls time.Now() directly.
type Clock func() time.Time

type Deps struct {
	Pool   *pgxpool.Pool
	Config *gameconfig.Bundle
	Signer *auth.Signer
	Now    Clock
}
