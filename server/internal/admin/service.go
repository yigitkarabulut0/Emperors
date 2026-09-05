package admin

import (
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

// Role ranking, so permission checks are comparisons rather than a growing
// switch that eventually disagrees with itself.
var roleRank = map[string]int{
	"analyst": 0, "moderator": 1, "designer": 2, "owner": 3,
}

// AtLeast reports whether a role meets a minimum.
func AtLeast(role, minimum string) bool {
	return roleRank[role] >= roleRank[minimum]
}
