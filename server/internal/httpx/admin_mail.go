package httpx

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
)

// The panel's Royal Mail, the diamond ledger and the job board.

func (a *adminAPI) mailSend(w http.ResponseWriter, r *http.Request) {
	var req admin.MailSend
	// A letter's attachments are a whole reward bundle; the 8 KB cap on the
	// game API is for taps, not for this.
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "malformed request body")
		return
	}
	v, err := a.svc.SendMail(r.Context(), who(r), req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) mailPreview(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	minLevel, _ := strconv.Atoi(q.Get("min_level"))
	maxLevel, _ := strconv.Atoi(q.Get("max_level"))
	activeDays, _ := strconv.Atoi(q.Get("active_days"))
	n, err := a.svc.MailAudience(r.Context(), q.Get("target"),
		admin.MailSegment{MinLevel: minLevel, MaxLevel: maxLevel, ActiveDays: activeDays})
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"audience": n})
}

func (a *adminAPI) mailBroadcasts(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	v, err := a.svc.Broadcasts(r.Context(), int32(limit))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"broadcasts": v})
}

func (a *adminAPI) mailRevoke(w http.ResponseWriter, r *http.Request) {
	var req struct {
		BroadcastID int64  `json:"broadcast_id"`
		Note        string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	pulled, err := a.svc.RevokeBroadcast(r.Context(), who(r), req.BroadcastID, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"unclaimed_pulled": pulled})
}

func (a *adminAPI) playerDiamonds(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id, err := uuid.Parse(q.Get("id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := a.svc.DiamondLedger(r.Context(), id, int32(limit), int32(offset))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"rows": rows})
}

func (a *adminAPI) jobs(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.JobRuns(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"jobs": v})
}
