// Package service holds the use-cases. Each one owns a transaction, reads
// state, calls the pure code in internal/game, writes the result, and returns.
//
// Handlers stay thin; game rules never appear here, only orchestration.
package service

import (
	"errors"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/realtime"
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

	// For the few things that are worth noticing but not worth failing an
	// action over -- a dropped quest tick, say. Nil is legal: tools and tests
	// that build a Deps by hand stay untouched, and the helpers check.
	Log *slog.Logger

	// ShopSecret seeds the deterministic shop roll. Never leaves the server:
	// anyone holding it could predict which window contains a legendary.
	ShopSecret []byte

	// Server-wide event modifiers, polled rather than queried per request.
	// Nil is legal and means no events -- Get() answers nil safely -- so tests
	// and tools that build a Deps by hand keep working untouched.
	Boosts *Boosts

	// IAP verifies what the App Store signs. Nil is legal: purchases answer
	// that they are not set up, and nothing else changes.
	IAP *iap.Verifier

	// Herald holds the advert unit the client plays and the keys a watched
	// advert's callback is checked against (ads.go). Nil is legal and is what
	// a realm with no adverts looks like: the store hides the section and the
	// routes answer that it is shut.
	Herald *Herald

	// Hall pushes a kingdom's own news to the lords standing in it: a line
	// said, a call for aid, the shared goal's bar moving. Nil is legal -- tools
	// and tests push nothing -- and every call goes through d.tell(), which
	// checks.
	//
	// The hall is never the truth. A frame that could not be sent costs a lord
	// one poll, and a push that failed must never fail the action that caused
	// it, so nothing here returns an error.
	Hall *realtime.Hub
}

// tell pushes one frame into a kingdom's room, if there is a hub and a room.
func (d Deps) tell(room uuid.UUID, kind string, payload any) {
	if d.Hall == nil || room == uuid.Nil {
		return
	}
	d.Hall.Publish(room, kind, payload)
}
