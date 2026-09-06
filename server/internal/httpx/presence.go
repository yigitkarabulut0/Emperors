package httpx

import (
	"net/http"

	"github.com/google/uuid"
)

// Presenter records that a player is here. The registry implements it; the
// interface keeps the router testable without one.
type Presenter interface {
	Touch(playerID uuid.UUID, device string, heartbeat bool)
	Leave(playerID uuid.UUID, device string)
}

// MarkPresent records every authenticated request against the live board.
//
// Placed here rather than at each of the forty-odd handlers for the same reason
// CreditTax is: one place cannot be forgotten, and the next endpoint anyone adds
// is counted for free. It costs one mutex and three map writes, which is nothing
// against a handler that talks to Frankfurt.
//
// It runs BEFORE CreditTax deliberately. Presence is a fact about the request
// arriving; it should not be contingent on a database write that may fail, and
// it should be recorded even for the player whose estate income query matches no
// rows -- which is every player without estates.
func MarkPresent(p Presenter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if pid, ok := PlayerID(r.Context()); ok {
				p.Touch(pid, DeviceID(r.Context()), false)
			}
			next.ServeHTTP(w, r)
		})
	}
}

// presence is the heartbeat endpoint: POST /v1/presence.
//
// Deliberately the emptiest handler in the game. It exists so a player who is
// holding the phone but not tapping still counts as being in the game -- the
// client makes no other request while idle, so without this the live board would
// show someone leaving while the app sits open in front of them.
//
// The body is optional. {"state":"leaving"} is the beacon iOS fires when the app
// is backgrounded, which turns a ninety-second timeout into an instant
// departure; anything else is an ordinary beat.
func (a *api) heartbeat(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "sign in again")
		return
	}
	if a.presence == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// Read the body if there is one, but never fail on it: a beacon sent while
	// the app is being suspended is worth acting on even if it arrives torn.
	var body struct {
		State string `json:"state"`
	}
	_ = decodeQuiet(r, &body)

	device := DeviceID(r.Context())
	if body.State == "leaving" {
		a.presence.Leave(pid, device)
	} else {
		a.presence.Touch(pid, device, true)
	}
	w.WriteHeader(http.StatusNoContent)
}
