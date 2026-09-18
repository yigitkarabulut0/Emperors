package httpx

import (
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
)

// The panel's billing desk. See internal/admin/billing.go.

func (a *adminAPI) billingSummary(w http.ResponseWriter, r *http.Request) {
	days, _ := strconv.Atoi(r.URL.Query().Get("days"))
	v, err := a.svc.BillingSummary(r.Context(), days)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) billingTransactions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := admin.TxnFilter{Environment: q.Get("env"), State: q.Get("state"), Search: q.Get("q")}
	if s := q.Get("player"); s != "" {
		id, err := uuid.Parse(s)
		if err != nil {
			WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player must be a uuid")
			return
		}
		f.PlayerID = &id
	}
	f.BeforeID, _ = strconv.ParseInt(q.Get("before"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	f.Limit = int32(limit)
	v, err := a.svc.Transactions(r.Context(), f)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"transactions": v})
}

func (a *adminAPI) billingNotifications(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	v, err := a.svc.Notifications(r.Context(), q.Get("open") == "1", int32(limit))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"notifications": v})
}

func (a *adminAPI) billingRetry(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID int64 `json:"id"`
	}
	if !decode(w, r, &req) {
		return
	}
	out, err := a.svc.RetryNotification(r.Context(), who(r), req.ID)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"outcome": out})
}

func (a *adminAPI) billingTakeBack(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TransactionID string `json:"transaction_id"`
		State         string `json:"state"`
		Note          string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	out, err := a.svc.TakeBack(r.Context(), who(r), req.TransactionID, req.State, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"outcome": out})
}

func (a *adminAPI) playerBilling(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.URL.Query().Get("id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	v, err := a.svc.PlayerBilling(r.Context(), id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) forgiveDebt(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	v, err := a.svc.ForgiveDebt(r.Context(), who(r), id, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// entitlement gives or takes back a lasting right by hand.
func (a *adminAPI) entitlement(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID    string `json:"player_id"`
		Entitlement string `json:"entitlement"`
		Grant       bool   `json:"grant"`
		Note        string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	change := a.svc.RevokeEntitlement
	if req.Grant {
		change = a.svc.GrantEntitlement
	}
	v, err := change(r.Context(), who(r), id, req.Entitlement, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- A/B tests --------------------------------------------------------------------

func (a *adminAPI) experiments(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.Experiments(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"experiments": v})
}

// --- promo codes ------------------------------------------------------------------

func (a *adminAPI) promos(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.Promos(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"codes": v})
}

func (a *adminAPI) promoCreate(w http.ResponseWriter, r *http.Request) {
	var req admin.PromoCreate
	if !decode(w, r, &req) {
		return
	}
	v, err := a.svc.CreatePromo(r.Context(), who(r), req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) promoDisable(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
		Note string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.svc.DisablePromo(r.Context(), who(r), req.Code, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) promoRedemptions(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.PromoRedemptions(r.Context(), r.URL.Query().Get("code"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"redemptions": v})
}
