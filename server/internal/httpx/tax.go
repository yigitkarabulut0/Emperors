package httpx

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
)

// TaxCrediter settles a player's estate income into their purse.
type TaxCrediter interface {
	CreditTax(ctx context.Context, playerID uuid.UUID) error
}

// CreditTax banks estate income before the handler runs.
//
// Estate income used to sit in an accumulator behind a Collect button. It is
// continuous now, which means every handler must see a purse that already
// includes it -- otherwise a player who has just earned enough for an upgrade is
// told they cannot afford it, which is the worst possible version of this
// feature.
//
// Doing it here rather than at each of the fourteen places that lock a player is
// deliberate: one place cannot be forgotten, and the next endpoint someone adds
// gets it for free. It costs a single UPDATE with no reads, because the hourly
// rate is cached on the player row.
//
// A failure is logged and swallowed. Not being paid a few gold this instant is a
// far smaller problem than refusing to serve the request -- the accrual anchor is
// untouched, so nothing is lost and the next request pays it.
func CreditTax(c TaxCrediter, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if pid, ok := PlayerID(r.Context()); ok {
				if err := c.CreditTax(r.Context(), pid); err != nil {
					log.Warn("could not credit estate income", "player", pid, "err", err)
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
