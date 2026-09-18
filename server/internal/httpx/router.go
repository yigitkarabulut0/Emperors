package httpx

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/legal"
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
	// Legal serves the Terms of Use and the Privacy Policy. Optional.
	Legal *legal.Pages
	// WSOrigins are the Origins the hall's websocket accepts. Empty means the
	// phone's own (which sends no Origin header at all); a browser build would
	// name its host here.
	WSOrigins []string
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

	// The Terms of Use and the Privacy Policy, which the App Store and the
	// Royal Store link to. Public, like the health checks.
	if d.Legal != nil {
		r.Get("/legal/terms", d.Legal.Terms)
		r.Get("/legal/privacy", d.Legal.Privacy)
	}

	a := &api{svc: d.Service, store: d.Store, log: d.Log, presence: d.Presence,
		verifier: d.Verifier, wsOrigins: d.WSOrigins}

	r.Route("/v1", func(r chi.Router) {
		// Unauthenticated: sign-up, sign-in and token rotation.
		r.Post("/auth/register", a.register)
		r.Post("/auth/login", a.login)
		r.Post("/auth/refresh", a.refresh)

		// App Store Server Notifications V2. Apple calls it; its signature is
		// the only credential that counts (service.AppleNotify).
		r.Post("/iap/apple/notify", a.iapNotify)

		// Herald's Tidings: Google calls this when a rewarded advert has been
		// watched, and the signature over its own query is the only credential
		// in it (service.CreditAdWatch).
		r.Get("/ads/admob/ssv", a.admobSSV)

		// Everything else needs a valid access token.
		r.Group(func(r chi.Router) {
			r.Use(RequireAuth(d.Verifier))
			// After auth, so it knows who it is watching.
			if d.Presence != nil {
				r.Use(MarkPresent(d.Presence))
			}

			// The heartbeat. Costs one map write and answers 204: it exists so a
			// player holding the phone without tapping still reads as in the
			// game, because the client makes no other request while idle.
			r.Post("/presence", a.heartbeat)
			// What only the phone can see: screens, sessions. See service/events.go.
			r.Post("/events", a.events)
			r.Get("/state", a.state)
			r.Get("/avatars", a.avatars)
			r.Post("/avatar", a.setAvatar)
			r.Post("/profile/rename", a.rename)
			r.Post("/account/delete", a.deleteAccount)
			r.Get("/away", a.away)
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

			// Purchases and the Royal Store. No action_seq on any of the money
			// routes: see httpx/purchases.go.
			r.Post("/iap/apple/verify", a.iapVerify)
			r.Post("/iap/apple/restore", a.iapRestore)
			r.Get("/store/court", a.courtStore)
			r.Post("/store/offers/seen", a.offersSeen)
			r.Post("/store/deals/claim", a.dealClaim)
			r.Post("/promo/redeem", a.promoRedeem)
			r.Get("/referral", a.referral)
			r.Post("/referral/claim", a.referralClaim)
			r.Post("/stipend/claim", a.stipendClaim)
			r.Post("/vip/gift", a.vipGift)
			r.Post("/steward/run", a.stewardRun)
			r.Get("/cosmetics", a.wardrobe)
			r.Post("/cosmetics/wear", a.wearCosmetic)
			r.Post("/cosmetics/buy", a.buyCosmetic)

			r.Get("/inventory", a.inventory)
			r.Post("/inventory/equip", a.equip)
			r.Post("/inventory/unequip", a.unequip)
			r.Post("/inventory/sell", a.sell)
			r.Post("/inventory/sell/batch", a.sellBatch)
			r.Post("/devices", a.registerDevice)
			r.Get("/legacy", a.legacy)
			r.Post("/legacy/begin", a.legacyBegin)
			r.Get("/collection", a.collection)
			r.Post("/collection/donate", a.donateItem)

			r.Get("/army", a.army)
			r.Post("/army/slot", a.buySlot)
			r.Post("/army/recruit", a.recruit)
			r.Get("/army/odds", a.recruitOdds)
			r.Post("/army/train", a.trainGone)
			r.Post("/army/dismiss", a.dismissSoldier)
			r.Post("/army/reroll", a.rerollSoldier)
			r.Post("/army/equip", a.equipSoldier)
			r.Post("/army/autoequip", a.autoEquip)

			r.Get("/estates", a.estates)
			r.Post("/estates/upgrade", a.buyUpgrade)
			r.Post("/estates/holding", a.buyHolding)
			// Gone, deliberately not 404: an .ipa already on a phone still asks
			// for this, and "this endpoint was removed" is a better answer than
			// "no such route" while those builds age out.
			r.Post("/estates/tax/claim", a.claimTaxGone)
			r.Post("/estates/storehouse/carry", a.carryStorehouse)

			r.Get("/kingdom", a.kingdom)
			r.Get("/kingdom/search", a.kingdomSearch)
			r.Get("/kingdoms/search", a.kingdomsSearch)
			r.Post("/kingdom/found", a.found)
			for _, act := range []string{"invite", "accept", "leave", "role", "donate", "upgrade", "rename",
				"join", "request/cancel", "decline", "requests/answer", "kick", "policy"} {
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
			// The daily loop (retention.json).
			r.Get("/cart", a.cart)
			r.Post("/cart/open", a.cartOpen)
			r.Get("/weekly", a.weekly)
			r.Post("/weekly/claim", a.weeklyClaim)
			r.Post("/weekly/chest", a.weeklyChest)
			r.Get("/road", a.road)
			r.Post("/road/claim", a.roadClaim)
			r.Post("/guide/advance", a.guideAdvance)
			r.Post("/guide/skip", a.guideSkip)
			r.Post("/guide/bandit", a.guideBandit)
			r.Post("/tokens/use", a.useToken)
			// Live ops (liveops.json).
			r.Post("/hourly/claim", a.hourlyClaim)
			r.Get("/festivals", a.festivals)
			r.Post("/festivals/claim", a.festivalsClaim)
			r.Get("/season", a.season)
			r.Post("/season/claim", a.seasonClaim)
			r.Post("/season/unlock", a.seasonUnlock)
			r.Get("/achievements", a.achievements)
			r.Post("/achievements/claim", a.achievementsClaim)

			// The Royal Mail: letters, and the rewards they carry.
			r.Get("/mail", a.mail)
			r.Post("/mail/read", a.mailRead)
			r.Post("/mail/claim", a.mailClaim)
			r.Post("/mail/claim-all", a.mailClaimAll)
			r.Post("/mail/delete", a.mailDelete)

			r.Get("/kingdom/shop", a.favourShop)
			r.Post("/kingdom/shop/buy", a.favourBuy)

			r.Get("/attack/targets", a.targets)
			r.Post("/attack", a.attack)
			r.Get("/attack/history", a.battleLog)
			r.Get("/battles/{id}", a.battleReplay)

			// Rekabet (pvp.json): the Attack tab's other sub-tabs, and the
			// Throne. CAMPAIGN is Wave 7's, below.
			r.Get("/arena", a.arena)
			r.Post("/arena/refresh", a.arenaRefresh)
			r.Post("/arena/fight", a.arenaFight)
			r.Get("/bounties", a.bounties)
			r.Post("/bounties/place", a.bountyPlace)
			r.Post("/bounties/claim", a.bountyClaim)
			r.Get("/throne", a.throne)
			r.Post("/throne/decree", a.throneDecree)

			// Sosyal (Wave 6). The hall, the roll, a rival's page and the
			// spyglass, the kingdom's help, and the settings behind them.
			r.Get("/chat", a.chat)
			r.Post("/chat", a.chatSend)
			r.Post("/chat/read", a.chatRead)
			r.Get("/chat/rules", a.chatRulesRead)
			r.Post("/chat/rules", a.chatAgree)
			r.Post("/chat/report", a.chatReport)
			r.Get("/realtime", a.realtime)
			r.Get("/friends", a.friends)
			r.Post("/friends/request", a.friendAsk)
			r.Post("/friends/answer", a.friendAnswer)
			r.Post("/friends/remove", a.friendRemove)
			r.Post("/friends/gift", a.giftSend)
			r.Post("/friends/gift/take", a.giftTake)
			r.Get("/lords/{id}", a.lord)
			r.Post("/lords/{id}/spy", a.lordSpy)
			r.Post("/lords/{id}/report", a.lordReport)
			r.Get("/help", a.help)
			r.Post("/help/ask", a.helpAsk)
			r.Post("/help/answer", a.helpAnswer)
			r.Post("/help/claim", a.helpClaim)
			r.Get("/settings", a.settings)
			r.Post("/settings/notify", a.settingsNotify)
			r.Post("/settings/privacy", a.settingsPrivacy)
			r.Post("/blocks", a.blockAdd)
			r.Post("/blocks/remove", a.blockRemove)

			// PvE ve derinlik (Wave 7). The campaign, the expeditions, the
			// forge and the talent tree.
			r.Get("/campaign", a.campaign)
			r.Get("/campaign/{id}", a.campaignChapter)
			r.Post("/campaign/fight", a.campaignFight)
			r.Post("/campaign/chest", a.campaignChest)
			r.Get("/hunt", a.hunt)
			r.Post("/hunt/send", a.huntSend)
			r.Post("/hunt/collect", a.huntCollect)
			r.Post("/hunt/recall", a.huntRecall)
			r.Post("/forge", a.forge)
			r.Get("/talents", a.talents)
			r.Post("/talents/buy", a.talentBuy)
			r.Post("/talents/respec", a.talentRespec)

			// Krallik Boss ve Savaslari (Wave 8). The kingdom's beast and the
			// kingdom's wars.
			r.Get("/boss", a.boss)
			r.Post("/boss/hit", a.bossHit)
			r.Get("/war", a.war)
			r.Post("/war/attack", a.warAttack)

			// Herald's Tidings: a ticket for one advert. What pays for it is
			// Google's callback above, never this.
			r.Post("/ads/watch", a.adsWatch)
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
