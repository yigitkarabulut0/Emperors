package httpx

import (
	"errors"
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/ads"
)

// HERALD'S TIDINGS -- the rewarded advert.
//
// Two doors, and they are not alike. `/v1/ads/watch` is the lord's own tap and
// carries their session; `/v1/ads/admob/ssv` is GOOGLE'S, carries no session at
// all, and is where the diamonds are actually paid. Its only credential is the
// signature over its own query -- which is why the handler hands the RAW query
// to the verifier and never a parsed copy of it (internal/ads says why, and a
// test there proves a re-encoded query stops verifying).

// adsWatch hands out a ticket for one advert.
func (a *api) adsWatch(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().StartAdWatch(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// admobSSV is Google's callback: the one thing that says an advert was watched.
//
// It always answers 200. Google retries a failure for hours, so a callback this
// server cannot pay -- a ticket that expired, an allowance already spent, a
// forgery -- must not be retried for ever; and a forged one must not learn from
// the status code whether it guessed a real ticket.
func (a *api) admobSSV(w http.ResponseWriter, r *http.Request) {
	err := a.s().CreditAdWatch(r.Context(), r.URL.RawQuery)
	switch {
	case err == nil:
	case errors.Is(err, ads.ErrInvalid), errors.Is(err, ads.ErrUnknownKey), errors.Is(err, ads.ErrStale):
		// Worth a line in the log: a run of these is either a rotation this
		// server missed or somebody trying it on.
		a.log.Warn("an advert callback was refused", "err", err)
	default:
		a.log.Error("an advert callback could not be paid", "err", err)
	}
	WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
