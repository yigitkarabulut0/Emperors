package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// maxBodyBytes caps request bodies. Every endpoint here takes a tiny JSON
// object; without a cap, a client can stream gigabytes into the decoder.
const maxBodyBytes = 8 << 10

type api struct {
	svc service.Deps
	log *slog.Logger
}

func decode(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields() // a typo'd field is a bug, not something to ignore
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

// fail maps a service error to a status code. Services never know about HTTP;
// this is the single place the translation happens.
func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrUsernameTaken):
		WriteProblem(w, r, http.StatusConflict, "username_taken", "that name is already taken")
	case errors.Is(err, service.ErrBadCredentials):
		WriteProblem(w, r, http.StatusUnauthorized, "bad_credentials", "wrong username or password")
	case errors.Is(err, service.ErrPlayerBanned):
		WriteProblem(w, r, http.StatusForbidden, "banned", "this account is banned")
	case errors.Is(err, service.ErrSessionInvalid):
		WriteProblem(w, r, http.StatusUnauthorized, "session_invalid", "please sign in again")
	case errors.Is(err, service.ErrNotFound):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, "not found")
	case errors.Is(err, service.ErrJobLocked):
		WriteProblem(w, r, http.StatusForbidden, "job_locked", "that job is not unlocked yet")
	case errors.Is(err, service.ErrNotEnoughEnergy):
		WriteProblem(w, r, http.StatusConflict, "not_enough_energy", "not enough energy")
	case errors.Is(err, service.ErrStaleAction):
		// 409, not 400: the request was well-formed, the client is just behind.
		// It should re-read state rather than retry blindly.
		WriteProblem(w, r, http.StatusConflict, "stale_action", "out of sync — reload state")
	case errors.Is(err, auth.ErrPasswordPolicy):
		WriteProblem(w, r, http.StatusBadRequest, "weak_password", err.Error())
	default:
		a.log.Error("unhandled service error", "err", err, "path", r.URL.Path)
		WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, "internal error")
	}
}

// --- auth ---

type registerReq struct {
	Username        string `json:"username"`
	Password        string `json:"password"`
	TZOffsetMinutes int    `json:"tz_offset_minutes"`
}

func (a *api) register(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.svc.Register(r.Context(), req.Username, req.Password, r.UserAgent(), req.TZOffsetMinutes)
	if err != nil {
		// A username that fails validation is a 400 with the reason, so the
		// signup form can say what is wrong instead of "invalid".
		if !isKnownServiceError(err) {
			WriteProblem(w, r, http.StatusBadRequest, "invalid_username", err.Error())
			return
		}
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusCreated, tok)
}

type loginReq struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (a *api) login(w http.ResponseWriter, r *http.Request) {
	var req loginReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.svc.Login(r.Context(), req.Username, req.Password, r.UserAgent())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, tok)
}

type refreshReq struct {
	RefreshToken string `json:"refresh_token"`
}

func (a *api) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshReq
	if !decode(w, r, &req) {
		return
	}
	tok, err := a.svc.Refresh(r.Context(), req.RefreshToken, r.UserAgent())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, tok)
}

// --- game ---

func (a *api) state(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	snap, err := a.svc.GetState(r.Context(), pid)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, snap)
}

type collectReq struct {
	JobID     string `json:"job_id"`
	ActionSeq int64  `json:"action_seq"`
}

func (a *api) collect(w http.ResponseWriter, r *http.Request) {
	pid, ok := PlayerID(r.Context())
	if !ok {
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "unauthenticated")
		return
	}
	var req collectReq
	if !decode(w, r, &req) {
		return
	}
	res, err := a.svc.Collect(r.Context(), pid, req.JobID, req.ActionSeq)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, res)
}

func isKnownServiceError(err error) bool {
	for _, e := range []error{
		service.ErrUsernameTaken, service.ErrBadCredentials, service.ErrPlayerBanned,
		service.ErrSessionInvalid, service.ErrNotFound, service.ErrJobLocked,
		service.ErrNotEnoughEnergy, service.ErrStaleAction, auth.ErrPasswordPolicy,
	} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}
