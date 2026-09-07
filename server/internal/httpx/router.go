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
	// Presence, when set, records who is in the game. Optional so the router
	// can still be built without one.
	Presence Presenter
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

	a := &api{svc: d.Service, store: d.Store, log: d.Log, presence: d.Presence}

	r.Route("/v1", func(r chi.Router) {
		// Unauthenticated: sign-up, sign-in and token rotation.
		r.Post("/auth/register", a.register)
		r.Post("/auth/login", a.login)
		r.Post("/auth/refresh", a.refresh)

		// Everything else needs a valid access token.
		r.Group(func(r chi.Router) {
			r.Use(RequireAuth(d.Verifier))
			// After auth, so it knows who it is watching. Before CreditTax,
			// because being here is a fact about the request arriving and must
			// not depend on a database write that can fail.
			if d.Presence != nil {
				r.Use(MarkPresent(d.Presence))
			}
			// After auth, so it knows who to pay; before every handler, so no
			// affordability check ever runs against a stale purse.
			r.Use(CreditTax(d.Service, d.Log))

			// The heartbeat. Costs one map write and answers 204: it exists so a
			// player holding the phone without tapping still reads as in the
			// game, because the client makes no other request while idle.
			r.Post("/presence", a.heartbeat)
			r.Get("/state", a.state)
			r.Get("/avatars", a.avatars)
			r.Post("/avatar", a.setAvatar)
			r.Post("/profile/rename", a.rename)
			r.Post("/collect", a.collect)
			r.Post("/collect/batch", a.collectBatch)
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
			r.Post("/inventory/sell/batch", a.sellBatch)
			r.Post("/inventory/reforge", a.reforge)
			r.Post("/devices", a.registerDevice)
			r.Get("/legacy", a.legacy)
			r.Post("/legacy/begin", a.legacyBegin)
			r.Get("/collection", a.collection)
			r.Post("/collection/donate", a.donateItem)

			r.Get("/army", a.army)
			r.Post("/army/slot", a.buySlot)
			r.Post("/army/recruit", a.recruit)
			r.Post("/army/autoroll", a.autoRoll)
			r.Get("/army/odds", a.recruitOdds)
			r.Post("/army/train", a.trainGone)
			r.Post("/army/dismiss", a.dismissSoldier)
			r.Post("/army/equip", a.equipSoldier)
			r.Post("/army/autoequip", a.autoEquip)

			r.Get("/estates", a.estates)
			r.Post("/estates/upgrade", a.buyUpgrade)
			r.Post("/estates/holding", a.buyHolding)
			// Gone, deliberately not 404: an .ipa already on a phone still asks
			// for this, and "this endpoint was removed" is a better answer than
			// "no such route" while those builds age out.
			r.Post("/estates/tax/claim", a.claimTaxGone)

			r.Get("/kingdom", a.kingdom)
			r.Get("/kingdom/search", a.kingdomSearch)
			r.Post("/kingdom/found", a.found)
			for _, act := range []string{"invite", "accept", "leave", "role", "donate", "upgrade"} {
				name := act
				r.Post("/kingdom/"+name, func(w http.ResponseWriter, req *http.Request) {
					a.kingdomAction(w, req, name)
				})
			}

			r.Get("/leaderboards/{board}", a.leaderboard)
			r.Get("/quests", a.quests)
			r.Post("/quests/claim", a.questClaim)
			r.Get("/daily", a.daily)
			r.Post("/daily/claim", a.dailyClaim)

			r.Get("/kingdom/shop", a.favourShop)
			r.Post("/kingdom/shop/buy", a.favourBuy)

			r.Get("/attack/targets", a.targets)
			r.Post("/attack", a.attack)
			r.Get("/attack/history", a.battleLog)
			r.Get("/battles/{id}", a.battleReplay)
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
