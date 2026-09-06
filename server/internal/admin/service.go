package admin

import (
	"time"

	"errors"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var (
	ErrNotFound       = errors.New("not found")
	ErrInvalidBalance = errors.New("balance document is invalid")
	ErrBadCredentials = errors.New("wrong username or password")
	ErrUnauthorized   = errors.New("not signed in")
	ErrForbidden      = errors.New("your role does not allow that")
)

// Service is the admin surface.
type Service struct {
	Pool   *pgxpool.Pool
	Config *gameconfig.Store
	Now    func() int64
}

// now is the clock, and it never panics.
//
// Now is an injection point for tests and is legitimately nil in production,
// where the wall clock is what you want. Calling s.Now() directly meant a nil
// field took down whichever endpoint happened to touch it -- which is how
// setting a player's energy returned a 500 while the same code path was fine
// for anyone whose luck happened to be zero.
func (s *Service) now() time.Time {
	if s.Now == nil {
		return time.Now().UTC()
	}
	return time.Unix(s.Now(), 0).UTC()
}

// Role ranking, so permission checks are comparisons rather than a growing
// switch that eventually disagrees with itself.
var roleRank = map[string]int{
	"analyst": 0, "moderator": 1, "designer": 2, "owner": 3,
}

// AtLeast reports whether a role meets a minimum.
func AtLeast(role, minimum string) bool {
	return roleRank[role] >= roleRank[minimum]
}
