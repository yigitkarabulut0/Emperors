package httpx

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
)

type playerCtxKey struct{}

// TokenVerifier is the slice of auth the middleware needs, kept as an interface
// so the router can be tested without a real signer.
type TokenVerifier interface {
	Verify(raw string) (playerID, sessionID string, err error)
}

// RequireAuth rejects a request without a valid access token and puts the
// player id on the context.
func RequireAuth(v TokenVerifier) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			raw, ok := strings.CutPrefix(header, "Bearer ")
			if !ok || raw == "" {
				WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "missing bearer token")
				return
			}

			pid, _, err := v.Verify(raw)
			if err != nil {
				// An expired token is distinguishable from a bad one, because the
				// client must know whether to refresh or to send the player back to
				// the login screen.
				code := CodeUnauthorized
				msg := "invalid token"
				if errors.Is(err, auth.ErrTokenExpired) {
					code = "token_expired"
					msg = "access token expired"
				}
				WriteProblem(w, r, http.StatusUnauthorized, code, msg)
				return
			}

			id, err := uuid.Parse(pid)
			if err != nil {
				WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "invalid token subject")
				return
			}

			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), playerCtxKey{}, id)))
		})
	}
}

// PlayerID returns the authenticated player, and false when unauthenticated.
func PlayerID(ctx context.Context) (uuid.UUID, bool) {
	id, ok := ctx.Value(playerCtxKey{}).(uuid.UUID)
	return id, ok
}
