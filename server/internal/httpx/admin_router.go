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
	"github.com/yigitkarabulut0/emperors/server/internal/adminstream"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

type adminAPI struct {
	svc *admin.Service
	log *slog.Logger
	// hub, when set, serves the live event stream. Optional so the router can be
	// built without one.
	hub *adminstream.Hub
	// origins is the websocket handshake allowlist. See AdminStream.
	origins []string
}

// AdminStream attaches the live event stream to the router.
type AdminStream struct {
	Hub     *adminstream.Hub
	Origins []string
}

type adminCtxKey struct{}

// AdminRouter mounts the live-ops surface.
//
// A separate router with its own middleware, not routes bolted onto the game
// API. Nothing a player can reach shares a path prefix, a middleware stack or a
// handler with anything that can grant currency, and in production this router
// binds to an interface players cannot reach at all.
func AdminRouter(svc *admin.Service, log *slog.Logger, stream *AdminStream) http.Handler {
	a := &adminAPI{svc: svc, log: log}
	if stream != nil {
		a.hub, a.origins = stream.Hub, stream.Origins
	}
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

		// Server-wide events.
		r.Get("/analytics", a.analytics)
		r.Get("/players/browse", a.browsePlayers)

		r.Get("/boosts", a.listBoosts)
		r.Post("/boosts", a.createBoost)
		r.Post("/boosts/revoke", a.revokeBoost)
		// The realm's calendar: the hourly schedule, festivals, the season.
		r.Get("/liveops/hourly", a.hourlySchedule)
		r.Post("/liveops/hourly", a.setHour)
		r.Get("/liveops/festivals", a.festivals)
		r.Post("/liveops/festivals", a.scheduleFestival)
		r.Post("/liveops/festivals/revoke", a.revokeFestival)
		r.Get("/liveops/festivals/board", a.festivalBoard)
		r.Get("/liveops/season", a.seasonSummary)

		// Rekabet (pvp.json): the arena's ladder, the board's escrow, the Throne.
		r.Get("/pvp/arena", a.pvpArena)
		r.Get("/pvp/bounties", a.pvpBounties)
		r.Post("/pvp/bounties/revoke", a.pvpBountyRevoke)
		r.Get("/pvp/throne", a.pvpThrone)
		r.Post("/pvp/throne/settle", a.pvpThroneSettle)

		// Sosyal (social.json): the halls' moderation queue.
		r.Get("/mod/queue", a.modQueue)
		r.Get("/mod/context", a.modContext)
		r.Get("/mod/mutes", a.modMutes)
		r.Post("/mod/hide", a.modHide)
		r.Post("/mod/mute", a.modMute)
		r.Post("/mod/unmute", a.modUnmute)
		r.Post("/mod/clear", a.modClear)

		// PvE ve derinlik (campaign.json, hunt.json, forge.json, talents.json):
		// the road, the roads, the anvil and the tree, read across the realm.
		r.Get("/depth", a.depth)
		r.Get("/kingdom-war", a.kingdomWar)

		r.Get("/audit", a.audit)

		// The Royal Mail from the panel, the diamond ledger, the job board.
		r.Post("/mail/send", a.mailSend)
		r.Get("/mail/preview", a.mailPreview)
		r.Get("/mail/broadcasts", a.mailBroadcasts)
		r.Post("/mail/revoke", a.mailRevoke)
		r.Get("/players/diamonds", a.playerDiamonds)
		r.Get("/jobs", a.jobs)

		// The billing desk: takings, purchases, the App Store's notifications,
		// and a lord's purchases with what they left.
		r.Get("/billing/summary", a.billingSummary)
		r.Get("/billing/transactions", a.billingTransactions)
		r.Get("/billing/notifications", a.billingNotifications)
		r.Post("/billing/notifications/retry", a.billingRetry)
		r.Post("/billing/take-back", a.billingTakeBack)
		r.Get("/players/billing", a.playerBilling)
		r.Post("/players/forgive-debt", a.forgiveDebt)
		r.Post("/players/entitlement", a.entitlement)

		// Dev tools: a server that is not production only (admin/dev.go).
		r.Get("/dev", a.devTools)
		r.Post("/dev/timewarp", a.devTimeWarp)
		r.Post("/dev/deeds", a.devDeeds)
		r.Post("/dev/jobs/run", a.devRunJob)
		r.Post("/dev/guide", a.devGuide)

		// A/B tests on offers, with each arm's results.
		r.Get("/experiments", a.experiments)

		// Promo codes.
		r.Get("/promo", a.promos)
		r.Post("/promo", a.promoCreate)
		r.Post("/promo/disable", a.promoDisable)
		r.Get("/promo/redemptions", a.promoRedemptions)

		// Who is in the game right now, as a plain read. The stream carries the
		// same information incrementally; this is what a fresh page load and
		// anything scripted asks for.
		r.Get("/live", a.live)
	})

	// The stream sits in its own group.
	//
	// It keeps requireAdmin -- the connection is as privileged as any other read
	// -- but drops Logger, which would emit a single line on disconnect with a
	// duration of however long the operator left the tab open. That is not a
	// request log entry, it is noise; the handler logs connect and disconnect
	// itself.
	if a.hub != nil {
		r.Group(func(r chi.Router) {
			r.Use(a.requireAdmin)
			r.Get("/stream", a.stream)
		})
	}
	return r
}

// stream upgrades to a websocket and pushes events until the panel goes away.
func (a *adminAPI) stream(w http.ResponseWriter, r *http.Request) {
	id := who(r)
	a.log.Info("admin stream opened", "admin", id.Username, "role", id.Role,
		"watchers", a.hub.Subscribers()+1)
	a.hub.Serve(w, r, map[string]any{"username": id.Username, "role": id.Role}, a.origins)
	a.log.Info("admin stream closed", "admin", id.Username, "watchers", a.hub.Subscribers())
}

func (a *adminAPI) live(w http.ResponseWriter, r *http.Request) {
	board, err := a.svc.Live(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, board)
}

func (a *adminAPI) requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := adminToken(r)
		id, err := a.svc.Authenticate(r.Context(), token)
		if err != nil {
			WriteProblem(w, r, http.StatusUnauthorized, CodeUnauthorized, "sign in again")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), adminCtxKey{}, id)))
	})
}

// adminToken finds the caller's token.
//
// Three places, because there are three callers. The Authorization header is
// what the panel's server-side fetches use. emperors_admin is the cookie this
// server sets at login. emperors_admin_session is the cookie the Next panel sets
// on its OWN origin -- and it matters here because a browser cannot put a header
// on a websocket handshake, so the socket is opened same-origin against the
// panel and proxied here with that cookie attached verbatim.
//
// The two cookie names are deliberately different. Cookies are port-blind, so a
// panel on localhost:3000 and this server on localhost:8081 share one jar for
// the host "localhost"; one name would have them overwrite each other during
// local development.
func adminToken(r *http.Request) string {
	if t, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok && t != "" {
		return t
	}
	for _, name := range []string{"emperors_admin", "emperors_admin_session"} {
		if c, err := r.Cookie(name); err == nil && c.Value != "" {
			return c.Value
		}
	}
	return ""
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
	case errors.Is(err, admin.ErrOutOfRange), errors.Is(err, service.ErrBadTakeBack):
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, err.Error())
	// The billing desk reaches into the game service, whose not-found and
	// not-configured are the desk's too.
	case errors.Is(err, service.ErrNotFound):
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, "not found")
	case errors.Is(err, admin.ErrNoGame):
		WriteProblem(w, r, http.StatusServiceUnavailable, "no_game", err.Error())
	case errors.Is(err, admin.ErrNoDevTools):
		WriteProblem(w, r, http.StatusForbidden, "dev_tools_off", err.Error())
	case errors.Is(err, admin.ErrUnavailable), errors.Is(err, service.ErrIAPUnavailable):
		WriteProblem(w, r, http.StatusServiceUnavailable, "iap_unavailable", "purchases are not configured on this server")
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
	_ = a.svc.Logout(r.Context(), adminToken(r))
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
	// The older currency-only form of /players/adjust. It used to be a second,
	// unguarded write path -- no diamond check, no transaction, no diamond
	// ledger -- so a removal past zero hit the CHECK constraint as a 500. It is
	// the guarded path now, with nothing but gold and diamonds.
	row, err := a.svc.AdjustPlayer(r.Context(), who(r), id, req.Gold, req.Diamonds, 0, 0, req.Note)
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

// --- server-wide events ---

func (a *adminAPI) listBoosts(w http.ResponseWriter, r *http.Request) {
	rows, err := a.svc.ListBoosts(r.Context(), 50)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"boosts":  rows,
		"buckets": admin.BoostableBuckets(),
	})
}

func (a *adminAPI) createBoost(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Bucket   string `json:"bucket"`
		AmountBP int64  `json:"amount_bp"`
		Hours    int    `json:"hours"`
		// Hours from now until it starts; 0 starts it at once.
		StartsIn int    `json:"starts_in_hours"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	row, err := a.svc.CreateBoost(r.Context(), who(r), req.Bucket, req.AmountBP, req.Hours, req.StartsIn, req.Note)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

func (a *adminAPI) revokeBoost(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID int64 `json:"id"`
	}
	if !decode(w, r, &req) {
		return
	}
	row, err := a.svc.RevokeBoost(r.Context(), who(r), req.ID)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, row)
}

// --- the realm's calendar ---

func (a *adminAPI) hourlySchedule(w http.ResponseWriter, r *http.Request) {
	rows, err := a.svc.HourlySchedule(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"hours": rows, "table": a.svc.HourlyTable()})
}

func (a *adminAPI) setHour(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Hour int64 `json:"hour"`
		// An event of the table to force; "none" to skip; "" to give the hour
		// back to the roll.
		Event string `json:"event"`
		Note  string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.svc.SetHour(r.Context(), who(r), req.Hour, req.Event, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.hourlySchedule(w, r)
}

func (a *adminAPI) festivals(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.Festivals(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) scheduleFestival(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Template string `json:"template"`
		// "YYYY-MM-DD HH:MM" UTC, or hours from now when empty.
		StartsAt string `json:"starts_at"`
		StartsIn int    `json:"starts_in_hours"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	if _, err := a.svc.ScheduleFestival(r.Context(), who(r), req.Template, req.StartsAt, req.StartsIn, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.festivals(w, r)
}

func (a *adminAPI) revokeFestival(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID int64 `json:"id"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.svc.RevokeFestival(r.Context(), who(r), req.ID); err != nil {
		a.fail(w, r, err)
		return
	}
	a.festivals(w, r)
}

func (a *adminAPI) festivalBoard(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the festival id is a number")
		return
	}
	rows, err := a.svc.FestivalBoard(r.Context(), id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"board": rows})
}

func (a *adminAPI) seasonSummary(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.SeasonSummary(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- population ---

func (a *adminAPI) analytics(w http.ResponseWriter, r *http.Request) {
	days, _ := strconv.Atoi(r.URL.Query().Get("days"))
	mins, _ := strconv.Atoi(r.URL.Query().Get("online"))
	v, err := a.svc.GetAnalytics(r.Context(), days, mins)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) browsePlayers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	minLevel, _ := strconv.Atoi(q.Get("min_level"))
	v, err := a.svc.BrowsePlayers(r.Context(), admin.BrowseFilter{
		Q: q.Get("q"), State: q.Get("state"),
		IncludeBots: q.Get("bots") == "1", MinLevel: minLevel,
		Sort: q.Get("sort"), Limit: limit, Offset: offset,
	})
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// --- Rekabet (Wave 5) ---
//
// The arena's ladder, the bounty board's escrow and the Throne. Reads take
// query params and writes take a body, as every other desk here does, and a
// write re-renders its own read so the panel never has to ask twice.

func (a *adminAPI) pvpArena(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	v, err := a.svc.ArenaLadder(r.Context(), who(r), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) pvpBounties(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	v, err := a.svc.Bounties(r.Context(), who(r), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) pvpBountyRevoke(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID   string `json:"id"`
		Note string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.ID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the bounty id is a uuid")
		return
	}
	if _, err := a.svc.RevokeBounty(r.Context(), who(r), id, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.pvpBounties(w, r)
}

// --- the moderation desk (admin/social.go) ---

func (a *adminAPI) depth(w http.ResponseWriter, r *http.Request) {
	hours, _ := strconv.Atoi(r.URL.Query().Get("hours"))
	v, err := a.svc.Depth(r.Context(), who(r), hours)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

// Krallik Boss ve Savaslari (Wave 8): the beasts standing and the week's wars.
func (a *adminAPI) kingdomWar(w http.ResponseWriter, r *http.Request) {
	hours, _ := strconv.Atoi(r.URL.Query().Get("hours"))
	v, err := a.svc.KingdomWar(r.Context(), who(r), hours)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) modQueue(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	v, err := a.svc.ModQueue(r.Context(), who(r), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) modContext(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.URL.Query().Get("id"))
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the line's id is a uuid")
		return
	}
	span, _ := strconv.Atoi(r.URL.Query().Get("span"))
	v, err := a.svc.ModContext(r.Context(), who(r), id, span)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"lines": v})
}

func (a *adminAPI) modMutes(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	v, err := a.svc.ModMutes(r.Context(), who(r), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"mutes": v})
}

func (a *adminAPI) modHide(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID   string `json:"id"`
		Hide bool   `json:"hide"`
		Note string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	id, err := uuid.Parse(req.ID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the line's id is a uuid")
		return
	}
	if err := a.svc.HideLine(r.Context(), who(r), id, req.Hide, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.modQueue(w, r)
}

func (a *adminAPI) modMute(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Minutes  int    `json:"minutes"`
		Reason   string `json:"reason"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	pid, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the lord's id is a uuid")
		return
	}
	if _, err := a.svc.MuteLord(r.Context(), who(r), pid, req.Minutes, req.Reason, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.modQueue(w, r)
}

func (a *adminAPI) modUnmute(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	pid, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the lord's id is a uuid")
		return
	}
	if err := a.svc.UnmuteLord(r.Context(), who(r), pid, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.modQueue(w, r)
}

// The lords' queue has one answer of its own: the desk has looked at this
// lord. What it decided to DO is a mute, or nothing, or a letter -- each with
// its own button and its own audit line.
func (a *adminAPI) modClear(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlayerID string `json:"player_id"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	pid, err := uuid.Parse(req.PlayerID)
	if err != nil {
		WriteProblem(w, r, http.StatusBadRequest, CodeBadRequest, "the lord's id is a uuid")
		return
	}
	if err := a.svc.ClearLordReports(r.Context(), who(r), pid, req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.modQueue(w, r)
}

func (a *adminAPI) pvpThrone(w http.ResponseWriter, r *http.Request) {
	v, err := a.svc.Throne(r.Context(), who(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, v)
}

func (a *adminAPI) pvpThroneSettle(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Note string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.svc.SettleThrone(r.Context(), who(r), req.Note); err != nil {
		a.fail(w, r, err)
		return
	}
	a.pvpThrone(w, r)
}
