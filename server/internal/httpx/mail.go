package httpx

import (
	"net/http"
)

// The Royal Mail, as the player reaches it.
//
// No action_seq on any of these: a letter is claimed once by the WHERE on its
// own row, and mail must never move the sequence the client's queued collects
// are counting on.

func (a *api) mail(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	v, err := a.s().GetMail(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// mailID reads the one field every letter action takes.
func mailID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	var req struct {
		ID int64 `json:"id"`
	}
	if !decode(w, r, &req) {
		return 0, false
	}
	if req.ID <= 0 {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a letter's id")
		return 0, false
	}
	return req.ID, true
}

func (a *api) mailRead(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	id, ok := mailID(w, r)
	if !ok {
		return
	}
	if err := a.s().ReadMail(r.Context(), pid, id); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) mailClaim(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	id, ok := mailID(w, r)
	if !ok {
		return
	}
	v, err := a.s().ClaimMail(r.Context(), pid, id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) mailClaimAll(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req struct{}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.s().ClaimAllMail(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *api) mailDelete(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	id, ok := mailID(w, r)
	if !ok {
		return
	}
	if err := a.s().DeleteMail(r.Context(), pid, id); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
