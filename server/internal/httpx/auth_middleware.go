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
type deviceCtxKey struct{}

// TokenVerifier is the slice of auth the middleware needs, kept as an interface
// so the router can be tested without a real signer.
type TokenVerifier interface {
	Verify(raw string) (playerID, deviceID string, err error)
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

			pid, device, err := v.Verify(raw)
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

			ctx := context.WithValue(r.Context(), playerCtxKey{}, id)
			// The second return used to be discarded here. Presence needs it: two
			// devices signed in as the same player are two devices on the live
			// board, and one signing out must not blank the other.
			ctx = context.WithValue(ctx, deviceCtxKey{}, device)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// PlayerID returns the authenticated player, and false when unauthenticated.
func PlayerID(ctx context.Context) (uuid.UUID, bool) {
	id, ok := ctx.Value(playerCtxKey{}).(uuid.UUID)
	return id, ok
}

// DeviceID returns the token family, which identifies the device and is stable
// across the fifteen-minute token rotation.
func DeviceID(ctx context.Context) string {
	s, _ := ctx.Value(deviceCtxKey{}).(string)
	return s
}
