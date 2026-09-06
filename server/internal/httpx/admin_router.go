package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

type adminAPI struct {
	svc *admin.Service
	log *slog.Logger
}

type adminCtxKey struct{}

// AdminRouter mounts the live-ops surface.
//
// A separate router with its own middleware, not routes bolted onto the game
// API. Nothing a player can reach shares a path prefix, a middleware stack or a
// handler with anything that can grant currency, and in production this router
// binds to an interface players cannot reach at all.
func AdminRouter(svc *admin.Service, log *slog.Logger) http.Handler {
	a := &adminAPI{svc: svc, log: log}
	r := chi.NewRouter()

	r.Use(RequestID)
	r.Use(Recover(log))
	r.Use(Logger(log))

	r.Post("/login", a.login)

	r.Group(func(r chi.Router) {
		r.Use(a.requireAdmin)
		r.Post("/logout", a.logout)
		r.Get("/me", a.me)

		r.Get("/dashboard", a.dashboard)
		r.Get("/players", a.searchPlayers)
		r.Post("/players/state", a.setState)
		r.Post("/players/currency", a.adjustCurrency)
		// Reads take query params, writes take a body -- the rule the rest of
		// this router already follows, so the panel's URL shape and the API's
		// stay independent of each other.
		r.Get("/players/detail", a.playerDetail)
		r.Post("/players/adjust", a.adjustPlayer)
		r.Post("/players/level", a.setLevel)
		r.Post("/players/energy", a.setEnergy)
		r.Post("/players/luck", a.setLuck)

		r.Get("/balance", a.getBalance)
		r.Get("/balance/versions", a.listVersions)
		r.Post("/balance/publish", a.publish)
		r.Post("/balance/rollback", a.rollback)

		r.Get("/audit", a.audit)
	})
	return r
}

func (a *adminAPI) requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if token == "" {
			// Also accept a cookie, so the panel can use an httpOnly one and keep
			// the token out of reach of any script on the page.
			if c, err := r.Cookie("emperors_admin"); err == nil {
				token = c.Value
			}
		}
		id, err := a.svc.Authenticate(r.Context(), token)
		if err != nil {
			WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "sign in again")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), adminCtxKey{}, id)))
	})
}

func who(r *http.Request) *admin.Identity {
	id, _ := r.Context().Value(adminCtxKey{}).(*admin.Identity)
	return id
}

func (a *adminAPI) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, admin.ErrBadCredentials):
		WriteProblem(w, r, http.StatusUnauthorized, "bad_credentials", "wrong username or password")
	case errors.Is(err, admin.ErrUnauthorized):
		WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "sign in again")
	case errors.Is(err, admin.ErrForbidden):
		WriteProblem(w, r, http.StatusForbidden, "forbidden", "your role does not allow that")
	case errors.Is(err, admin.ErrNotFound):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, "not found")
	case errors.Is(err, admin.ErrInvalidBalance):
		WriteProblem(w, r, http.StatusBadRequest, "invalid_balance", err.Error())
	// A form the operator can fix is a 400 with the reason, not a 500. Without
	// these the panel would show "internal error" for "you typed nothing".
	case errors.Is(err, admin.ErrNothingToDo):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, err.Error())
	case errors.Is(err, admin.ErrOutOfRange):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, err.Error())
	default:
		a.log.Error("admin error", "err", err, "path", r.URL.Path)
		WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, err.Error())
	}
}

func (a *adminAPI) login(w http.ResponseWriter, r *http.Request) {
	var req struct{ Username, Password string }
	if !decode(w, r, &req) {
		return
	}
	token, id, err := a.svc.Login(r.Context(), req.Username, req.Password)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: "emperors_admin", Value: token, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode,
		MaxAge: int(admin.AdminSessionTTL.Seconds()),
	})
	WriteJSON(w, http.StatusOK, map[string]any{
		"token": token, "username": id.Username, "role": id.Role,
	})
}

func (a *adminAPI) logout(w http.ResponseWriter, r *http.Request) {
	token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if c, err := r.Cookie("emperors_admin"); err == nil && token == "" {
		token = c.Value
	}
	_ = a.svc.Logout(r.Context(), token)
	http.SetCookie(w, &http.Cookie{Name: "emperors_admin", Value: "", Path: "/", MaxAge: -1})
	WriteJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *adminAPI) me(w http.ResponseWriter, r *http.Request) {
	id := who(r)
	WriteJSON(w, http.StatusOK, map[string]any{"username": id.Username, "role": id.Role})
}

func (a *adminAPI) dashboard(w http.ResponseWriter, r *http.Request) {
	days, _ := strconv.Atoi(r.URL.Query().Get("days"))
	d, err := a.svc.Dashboard(r.Context(), days)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, d)
}

func (a *adminAPI) searchPlayers(w http.ResponseWriter, r *http.Request) {
	rows, err := a.svc.SearchPlayers(r.Context(), r.URL.Query().Get("q"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"players": rows})
}

func (a *adminAPI) setState(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		State    string `json:"state"`
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
	row, err := a.svc.SetState(r.Context(), who(r), id, req.State, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

func (a *adminAPI) adjustCurrency(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Gold     int64  `json:"gold"`
		Diamonds int64  `json:"diamonds"`
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
	row, err := a.svc.AdjustCurrency(r.Context(), who(r), id, req.Gold, req.Diamonds, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

// getBalance returns the live document, which is what the editor loads.
func (a *adminAPI) getBalance(w http.ResponseWriter, r *http.Request) {
	b := a.svc.Config.Get()
	raw, err := gameconfig.MarshalDoc(b.Doc())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	WriteJSON(w, http.StatusOK, map[string]any{
		"version":  b.Version,
		"document": json.RawMessage(raw),
	})
}

func (a *adminAPI) listVersions(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.Versions(r.Context(), 50)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"versions": v})
}

func (a *adminAPI) publish(w http.ResponseWriter, r *http.Request) {
	id := who(r)
	if !admin.AtLeast(id.Role, "designer") {
		a.fail(w, r, admin.ErrForbidden)
		return
	}
	// The editor sends a whole document, so a publish is atomic — there is never
	// a moment where the job ladder is new and the item table is still old.
	var req struct {
		Document json.RawMessage `json:"document"`
		Note     string          `json:"note"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "malformed request body")
		return
	}
	doc, err := gameconfig.ParseDoc(req.Document)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, "invalid_balance", err.Error())
		return
	}
	v, err := a.svc.Publish(r.Context(), doc, req.Note, id.Username)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	a.svc.Audit(r.Context(), id, "balance.publish", strconv.FormatInt(v.ID, 10), nil, v, req.Note)
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) rollback(w http.ResponseWriter, r *http.Request) {
	id := who(r)
	if !admin.AtLeast(id.Role, "designer") {
		a.fail(w, r, admin.ErrForbidden)
		return
	}
	var req struct {
		VersionID int64  `json:"version_id"`
		Reason    string `json:"reason"`
	}
	if !decode(w, r, &req) {
		return
	}
	v, err := a.svc.Rollback(r.Context(), req.VersionID, id.Username, req.Reason)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	a.svc.Audit(r.Context(), id, "balance.rollback", strconv.FormatInt(v.ID, 10), nil, v, req.Reason)
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) audit(w http.ResponseWriter, r *http.Request) {
	rows, err := a.svc.AuditLog(r.Context(), 100)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"entries": rows})
}

// --- the per-player control surface ---
//
// Reads take a query param, writes take a body, matching the rest of this
// router. Each handler is a thin shell: the role check, the invariants and the
// audit row all live in admin.Service, so a new route cannot accidentally skip
// one of them.

func (a *adminAPI) playerDetail(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.URL.Query().Get("id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "id must be a uuid")
		return
	}
	// The luck the operator is considering, so the response can price it.
	preview, _ := strconv.ParseInt(r.URL.Query().Get("preview"), 10, 32)
	v, err := a.svc.GetPlayerDetail(r.Context(), id, int32(preview))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) adjustPlayer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID   string `json:"player_id"`
		Gold       int64  `json:"gold"`
		Diamonds   int64  `json:"diamonds"`
		XP         int64  `json:"xp"`
		StatPoints int32  `json:"stat_points"`
		Note       string `json:"note"`
	}
	id, ok := decodePlayer(w, r, &req, &req.PlayerID)
	if !ok {
		return
	}
	row, err := a.svc.AdjustPlayer(r.Context(), who(r), id,
		req.Gold, req.Diamonds, req.XP, req.StatPoints, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

func (a *adminAPI) setLevel(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Level    int32  `json:"level"`
		Note     string `json:"note"`
	}
	id, ok := decodePlayer(w, r, &req, &req.PlayerID)
	if !ok {
		return
	}
	row, err := a.svc.SetLevel(r.Context(), who(r), id, req.Level, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

func (a *adminAPI) setEnergy(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Energy   int64  `json:"energy"`
		Note     string `json:"note"`
	}
	id, ok := decodePlayer(w, r, &req, &req.PlayerID)
	if !ok {
		return
	}
	row, err := a.svc.SetEnergy(r.Context(), who(r), id, req.Energy, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

func (a *adminAPI) setLuck(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		LuckBP   int32  `json:"luck_bp"`
		// Days from now. 0 means permanent, which SetLuck gates behind a
		// designer role -- an override nobody remembers is the failure mode.
		Days int    `json:"days"`
		Note string `json:"note"`
	}
	id, ok := decodePlayer(w, r, &req, &req.PlayerID)
	if !ok {
		return
	}
	var expires *time.Time
	if req.Days > 0 {
		t := time.Now().UTC().AddDate(0, 0, req.Days)
		expires = &t
	}
	row, err := a.svc.SetLuck(r.Context(), who(r), id, req.LuckBP, expires, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

// decodePlayer reads a body and pulls the player id out of it, so five handlers
// do not each repeat the same two failure modes.
func decodePlayer(w http.ResponseWriter, r *http.Request, req any, field *string) (uuid.UUID, bool) {
	if !decode(w, r, req) {
		return uuid.Nil, false
	}
	id, err := uuid.Parse(*field)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "player_id must be a uuid")
		return uuid.Nil, false
	}
	return id, true
}
