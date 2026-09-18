package httpx

import (
	"net/http"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The panel's dev tools (admin/dev.go): answered with 403 dev_tools_off by a
// production server, which is never given them.

func (a *adminAPI) devTools(w http.ResponseWriter, r *http.Request) {
	jobs := []string{}
	for _, j := range service.ScheduledJobs() {
		jobs = append(jobs, j.Name)
	}
	kinds := make([]string, 0, len(deeds.All))
	for _, k := range deeds.All {
		kinds = append(kinds, string(k))
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"available": a.svc.DevAvailable(), "max_hours": service.DevWarpMaxHours,
		"jobs": jobs, "deeds": kinds,
	})
}

func (a *adminAPI) devTimeWarp(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Hours    int    `json:"hours"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.svc.DevTimeWarp(r.Context(), who(r), id, req.Hours); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"warped_hours": req.Hours})
}

func (a *adminAPI) devDeeds(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Deed     string `json:"deed"`
		N        int64  `json:"n"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.svc.DevAddDeeds(r.Context(), who(r), id, req.Deed, req.N); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deed": req.Deed, "added": req.N})
}

func (a *adminAPI) devRunJob(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.svc.DevRunJob(r.Context(), who(r), req.Name); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"ran": req.Name})
}

func (a *adminAPI) devGuide(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return
	}
	if err := a.svc.DevRestartGuide(r.Context(), who(r), id); err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"guide": "restarted"})
}
