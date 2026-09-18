package httpx

import (
	"errors"
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Promo codes and bringing a friend. `device` is the phone's own identifier;
// the server keeps only a keyed hash of it.

type promoReq struct {
	Code   string `json:"code"`
	Device string `json:"device"`
}

func (a *api) promoRedeem(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req promoReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().RedeemPromo(r.Context(), pid, req.Code, req.Device)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) referral(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetReferral(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) referralClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req promoReq
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimReferral(r.Context(), pid, req.Code, req.Device)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// promoProblem maps the promo and referral errors.
func promoProblem(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case errors.Is(err, service.ErrNoDevice):
		WriteProblem(w, r, http.StatusBadRequest, "no_device", err.Error())
	case errors.Is(err, service.ErrPromoInvalid):
		WriteProblem(w, r, http.StatusNotFound, "promo_invalid", err.Error())
	case errors.Is(err, service.ErrPromoUsed):
		WriteProblem(w, r, http.StatusConflict, "promo_used", err.Error())
	case errors.Is(err, service.ErrPromoTooMany):
		WriteProblem(w, r, http.StatusTooManyRequests, "too_many_attempts", err.Error())
	case errors.Is(err, service.ErrReferralClosed):
		WriteProblem(w, r, http.StatusConflict, "referral_closed", err.Error())
	case errors.Is(err, service.ErrReferralCode):
		WriteProblem(w, r, http.StatusNotFound, "referral_invalid", err.Error())
	case errors.Is(err, service.ErrReferralSelf):
		WriteProblem(w, r, http.StatusConflict, "referral_self", err.Error())
	case errors.Is(err, service.ErrReferralLimit):
		WriteProblem(w, r, http.StatusConflict, "referral_limit", err.Error())
	default:
		return false
	}
	return true
}
