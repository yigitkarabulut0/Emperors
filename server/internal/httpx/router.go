package httpx

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Deps is what the router needs from the rest of the application. Keeping it
// an interface set (rather than concrete services) is what lets the router be
// tested without a database.
type Deps struct {
	Log      *slog.Logger
	Health   HealthChecker
	Version  string
	Service  service.Deps
	Verifier TokenVerifier
	// Store, when set, makes every request read the live balance version rather
	// than the one that happened to be loaded at boot.
	Store *gameconfig.Store
}

// HealthChecker reports whether dependencies are reachable.
type HealthChecker interface {
	// Ping verifies the database answers. Used by /readyz.
	Ping(r *http.Request) error
	// Motto returns a value read from Postgres. This exists so M0 can prove the
	// whole pipe — phone -> TLS -> Go -> Neon -> back — with one screen.
	Motto(r *http.Request) (string, string, error)
}

// NewRouter wires the middleware stack and routes.
//
// Four middleware profiles, which is precisely why this is chi and not the
// stdlib mux: /healthz gets nothing, /v1 gets the full game stack, /admin will
// get its own, and only chi exposes RoutePattern() for low-cardinality logging.
func NewRouter(d Deps) http.Handler {
	r := chi.NewRouter()

	r.Use(RequestID)
	r.Use(Recover(d.Log))
	r.Use(Logger(d.Log))

	// Liveness: is the process up? Never touches the database — a DB blip must
	// not get the container killed.
	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]any{"ok": true, "version": d.Version})
	})

	// Readiness: should this instance receive traffic? Does touch the database.
	r.Get("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if err := d.Health.Ping(r); err != nil {
			d.Log.Warn("readiness failed", "err", err)
			WriteProblem(w, r, http.StatusServiceUnavailable, CodeUnavailable, "database unreachable")
			return
		}
		WriteJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	a := &api{svc: d.Service, store: d.Store, log: d.Log}

	r.Route("/v1", func(r chi.Router) {
		// Unauthenticated: sign-up, sign-in and token rotation.
		r.Post("/auth/register", a.register)
		r.Post("/auth/login", a.login)
		r.Post("/auth/refresh", a.refresh)

		// Everything else needs a valid access token.
		r.Group(func(r chi.Router) {
			r.Use(RequireAuth(d.Verifier))
			r.Get("/state", a.state)
			r.Get("/avatars", a.avatars)
			r.Post("/avatar", a.setAvatar)
			r.Post("/collect", a.collect)
			r.Post("/stats/spend", a.spendStats)

			r.Post("/treasury/deposit", a.deposit)
			r.Post("/treasury/withdraw", a.withdraw)

			r.Get("/shop", a.shop)
			r.Post("/shop/buy", a.buy)
			r.Post("/shop/reroll", a.rerollShop)

			r.Get("/store", a.diamondStore)
			r.Post("/store/buy", a.buyStoreGood)

			r.Get("/inventory", a.inventory)
			r.Post("/inventory/equip", a.equip)
			r.Post("/inventory/unequip", a.unequip)
			r.Post("/inventory/sell", a.sell)

			r.Get("/army", a.army)
			r.Post("/army/slot", a.buySlot)
			r.Post("/army/recruit", a.recruit)
			r.Post("/army/train", a.train)
			r.Post("/army/dismiss", a.dismissSoldier)
			r.Post("/army/equip", a.equipSoldier)

			r.Get("/estates", a.estates)
			r.Post("/estates/upgrade", a.buyUpgrade)
			r.Post("/estates/holding", a.buyHolding)
			r.Post("/estates/tax/claim", a.claimTax)

			r.Get("/kingdom", a.kingdom)
			r.Get("/kingdom/search", a.kingdomSearch)
			r.Post("/kingdom/found", a.found)
			for _, act := range []string{"invite", "accept", "leave", "role", "donate", "upgrade"} {
				name := act
				r.Post("/kingdom/"+name, func(w http.ResponseWriter, req *http.Request) {
					a.kingdomAction(w, req, name)
				})
			}

			r.Get("/attack/targets", a.targets)
			r.Post("/attack", a.attack)
		})

		r.Get("/ping", func(w http.ResponseWriter, r *http.Request) {
			motto, now, err := d.Health.Motto(r)
			if err != nil {
				d.Log.Error("ping query", "err", err)
				WriteProblem(w, r, http.StatusServiceUnavailable, CodeUnavailable, "database unreachable")
				return
			}
			WriteJSON(w, http.StatusOK, map[string]any{
				"pong":    true,
				"motto":   motto,
				"db_time": now,
				"version": d.Version,
			})
		})
	})

	r.NotFound(func(w http.ResponseWriter, r *http.Request) {
		WriteProblem(w, r, http.StatusNotFound, CodeNotFound, "no such endpoint")
	})

	return r
}
