package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Purchases, the Royal Store and Splendour, as the player reaches them.
//
// No action_seq on the purchase routes: money arrives on the App Store's
// schedule, and a purchase must never move the sequence the client's queued
// collects are counting on. Buying a cosmetic with diamonds is an ordinary
// sequenced spend.

// A signed transaction carries three certificates and runs to about 5 KB; a
// restore sends one per lasting right. The game API's 8 KB cap is for taps.
const (
	jwsBodyBytes     = 32 << 10
	restoreBodyBytes = 512 << 10
	notifyBodyBytes  = 256 << 10
)

// decodeLimited is decode with its own size cap.
func decodeLimited(w http.ResponseWriter, r *http.Request, into any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		msg := "malformed request body"
		if errors.Is(err, io.EOF) {
			msg = "request body is empty"
		}
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, msg)
		return false
	}
	return true
}

type verifyReq struct {
	JWS string `json:"jws"`
}

func (a *api) iapVerify(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req verifyReq
	if !decodeLimited(w, r, &req, jwsBodyBytes) {
		return
	}
	v, err := a.s().VerifyApple(r.Context(), pid, req.JWS)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type restoreReq struct {
	JWS []string `json:"jws"`
}

func (a *api) iapRestore(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req restoreReq
	if !decodeLimited(w, r, &req, restoreBodyBytes) {
		return
	}
	v, err := a.s().RestoreApple(r.Context(), pid, req.JWS)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// iapNotify is App Store Server Notifications V2. Public: Apple calls it, and
// the signature is the only credential that counts. Stored before it is acted
// on; 200 once stored, so Apple stops resending what we already hold.
func (a *api) iapNotify(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SignedPayload string `json:"signedPayload"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, notifyBodyBytes)
	// Not strict: the body is Apple's, and a field they add must not fail it.
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.SignedPayload == "" {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "no signedPayload")
		return
	}
	if err := a.s().AppleNotify(r.Context(), req.SignedPayload); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *api) courtStore(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetCourtStore(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) offersSeen(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	if err := a.s().SeeOffers(r.Context(), pid); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) stipendClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().ClaimStipend(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) vipGift(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().ClaimVIPGift(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) stewardRun(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().RunSteward(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type dealClaimReq struct {
	Slot      int   `json:"slot"`
	ActionSeq int64 `json:"action_seq"`
}

// dealClaim takes one of the day's deals: the gift, or one bought with diamonds.
func (a *api) dealClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req dealClaimReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimDeal(r.Context(), pid, req.Slot, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) wardrobe(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetWardrobe(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type wearReq struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

func (a *api) wearCosmetic(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req wearReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().WearCosmetic(r.Context(), pid, req.Kind, req.ID)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

type buyCosmeticReq struct {
	ID        string `json:"id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) buyCosmetic(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req buyCosmeticReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().BuyCosmetic(r.Context(), pid, req.ID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// purchaseProblem maps the purchase errors. The client finishes a transaction
// on a 2xx only; every code here leaves it unfinished except the ones that say
// it can never be delivered (invalid, another app, another account).
func purchaseProblem(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case errors.Is(err, service.ErrIAPUnavailable):
		WriteProblem(w, r, http.StatusServiceUnavailable, "iap_unavailable", err.Error())
	case errors.Is(err, service.ErrIAPInvalid):
		WriteProblem(w, r, http.StatusBadRequest, "iap_invalid", service.ErrIAPInvalid.Error())
	case errors.Is(err, service.ErrIAPWrongApp):
		WriteProblem(w, r, http.StatusBadRequest, "iap_wrong_app", service.ErrIAPWrongApp.Error())
	case errors.Is(err, service.ErrIAPOwnedByAnother):
		WriteProblem(w, r, http.StatusConflict, "owned_by_another_account", err.Error())
	case errors.Is(err, service.ErrIAPUnknownProduct):
		WriteProblem(w, r, http.StatusConflict, "unknown_product", service.ErrIAPUnknownProduct.Error())
	case errors.Is(err, service.ErrNothingToClaim):
		WriteProblem(w, r, http.StatusConflict, "nothing_to_claim", err.Error())
	case errors.Is(err, service.ErrNotSteward):
		WriteProblem(w, r, http.StatusForbidden, "not_steward", err.Error())
	case errors.Is(err, service.ErrCosmeticLocked):
		WriteProblem(w, r, http.StatusConflict, "cosmetic_locked", err.Error())
	case errors.Is(err, service.ErrCosmeticNotSold):
		WriteProblem(w, r, http.StatusConflict, "cosmetic_not_sold", err.Error())
	case errors.Is(err, service.ErrCosmeticOwned):
		WriteProblem(w, r, http.StatusConflict, "cosmetic_owned", err.Error())
	case errors.Is(err, service.ErrDealStale):
		WriteProblem(w, r, http.StatusConflict, "deal_stale", err.Error())
	default:
		return false
	}
	return true
}
