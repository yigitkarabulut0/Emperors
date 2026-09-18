// Command api is the Emperors game server: one stateless binary, authoritative
// for every number in the game.
package main

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/adminstream"
	"github.com/yigitkarabulut0/emperors/server/internal/ads"
	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/health"
	"github.com/yigitkarabulut0/emperors/server/internal/httpx"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/legal"
	"github.com/yigitkarabulut0/emperors/server/internal/obs"
	"github.com/yigitkarabulut0/emperors/server/internal/presence"
	"github.com/yigitkarabulut0/emperors/server/internal/realtime"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	// distroless carries no shell and no curl, so the container healthcheck runs
	// this binary against itself rather than shelling out.
	healthcheck := flag.Bool("healthcheck", false, "probe the local /healthz endpoint and exit")
	flag.Parse()
	if *healthcheck {
		os.Exit(probeSelf())
	}

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

// devAdKeyID is the key id a local realm's hand-signed advert callback carries.
// Google's ids are its own; this is only ever used with EMPERORS_ADMOB_DEV_KEY,
// which config refuses in prod.
const devAdKeyID = 1

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := obs.NewLogger(cfg.LogLevel, cfg.Env)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	startCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	pool, err := db.NewAppPool(startCtx, cfg.DatabaseURL, db.Options{
		MaxConns:         cfg.MaxConns,
		MinConns:         cfg.MinConns,
		StatementTimeout: cfg.StatementTimeout,
		LockTimeout:      cfg.LockTimeout,
	})
	if err != nil {
		return err
	}
	defer pool.Close()

	// Neon autosuspends idle computes; the first query after a cold start pays
	// the wake-up. Do it here so it lands on boot, not on a player's first tap.
	if err := pool.Ping(startCtx); err != nil {
		return fmt.Errorf("database unreachable at startup: %w", err)
	}
	log.Info("database connected", "max_conns", cfg.MaxConns)

	// Fail fast on a bad balance bundle: a config that would let a player earn
	// infinite gold must stop the boot, not reach players.
	seed, err := gameconfig.LoadSeed()
	if err != nil {
		return fmt.Errorf("game config: %w", err)
	}

	// The seed keeps the server serving even with an empty database; a published
	// version supersedes it the moment there is one.
	store := gameconfig.NewStore(seed, admin.BalanceLoader{Pool: pool}, log)
	if err := store.Refresh(startCtx); err != nil {
		log.Warn("could not load a published balance version, running on the seed", "err", err)
	}
	bundle := store.Get()
	log.Info("game config loaded", "version", bundle.Version, "jobs", len(bundle.Jobs.Jobs))

	// Polling rather than LISTEN/NOTIFY: a poll survives a dropped connection
	// with no reconnect logic, and balance data taking up to a minute to reach
	// players is entirely acceptable.
	go store.Watch(ctx, 30*time.Second)

	signer, err := auth.NewSigner(cfg.TokenSeed, time.Now)
	if err != nil {
		return err
	}

	// Server-wide event modifiers. Loaded once at boot and then polled, because
	// loadEffects runs on every authenticated request and a query there would
	// put a database round trip in front of every action in the game.
	boosts := service.NewBoosts(pool, log, time.Now)
	if err := boosts.Refresh(startCtx); err != nil {
		log.Warn("could not load server boosts, starting with none", "err", err)
	}
	go boosts.Poll(ctx, 30*time.Second)

	// Purchases: every App Store signature is proved against Apple's root. A
	// dev root (cmd/iapmint's) is trusted instead only outside prod, which the
	// config refuses to start with.
	root, err := iap.LoadRoot(cfg.IAPDevRoot)
	if err != nil {
		return fmt.Errorf("purchases: %w", err)
	}
	verifier := &iap.Verifier{Root: root, BundleID: cfg.IAPBundleID, AppAppleID: cfg.IAPAppAppleID,
		AllowSandbox: cfg.IAPAllowSandbox}
	log.Info("purchases configured", "bundle", cfg.IAPBundleID, "sandbox", cfg.IAPAllowSandbox,
		"root", root.Subject.CommonName)

	// Herald's Tidings. The herald stays SHUT until this server is given an
	// advert unit to play: a WATCH plate over a placement with no advert is a
	// button that does nothing, so the store hides the whole section. The keys
	// a callback is checked against are Google's published ones, fetched here
	// and again if a rotation ever arrives (service.Herald).
	herald := &service.Herald{UnitID: cfg.AdMobUnitID, KeysURL: cfg.AdMobKeysURL}
	if cfg.AdMobUnitID != "" {
		if cfg.AdMobDevKey != "" {
			// A local realm signing its own callbacks. config refuses this in
			// prod.
			pub, kerr := ads.ParsePublicKey(cfg.AdMobDevKey)
			if kerr != nil {
				return fmt.Errorf("adverts: EMPERORS_ADMOB_DEV_KEY: %w", kerr)
			}
			herald.Trust(map[int64]*ecdsa.PublicKey{devAdKeyID: pub})
			log.Warn("adverts trust a DEV key, not Google's", "unit", cfg.AdMobUnitID)
		} else if kerr := herald.Refresh(ctx); kerr != nil {
			// Not fatal: a herald with no keys is a shut herald, and the next
			// callback fetches them again. A store that could not open because
			// gstatic was slow would be worse.
			log.Warn("adverts could not fetch Google's verifier keys", "err", kerr)
		}
		log.Info("adverts configured", "unit", cfg.AdMobUnitID, "open", herald.Open())
	}

	// The kingdoms' halls. One hub, a room per kingdom, pushing only what
	// another lord in the same room did -- everything a lord does themselves
	// arrives in the answer to their own tap (internal/realtime).
	hall := realtime.New(time.Now, log.With("surface", "hall"))

	svc := service.Deps{
		Pool: pool, Config: bundle, Signer: signer, Now: time.Now, Log: log,
		ShopSecret: cfg.ShopSecret,
		Boosts:     boosts,
		IAP:        verifier,
		Herald:     herald,
		Hall:       hall,
	}

	// The world's own clock: the work that belongs to no player's request --
	// reputation decay, leaderboards, and everything scheduled after them. Each
	// job runs once per period across restarts (a claim row, not a timer), and
	// every run reads the LIVE balance: the loops this replaced were handed the
	// bundle loaded at boot and never saw a publish.
	host, _ := os.Hostname()
	runner := &service.Runner{
		Store: store, Base: svc, Log: log.With("surface", "jobs"), Now: time.Now,
		Instance: fmt.Sprintf("%s:%d", host, os.Getpid()),
		Jobs:     service.ScheduledJobs(),
	}
	go runner.Run(ctx, 30*time.Second)

	// Who is in the game right now. Held in memory on purpose: this process
	// serves both listeners, so a fact written by a player's request on :8080 is
	// readable by an admin's request on :8081 with nothing in between.
	live := presence.New(time.Now, log)
	presenceStore := presence.NewStore(pool)
	// Seeded from last_seen_at so a deploy does not report an exodus that never
	// happened. Counts say "reconciling" until the process is old enough to have
	// heard from people itself.
	if seen, err := presenceStore.Recent(startCtx, time.Now().Add(-presence.IdleWindow)); err != nil {
		log.Warn("could not seed presence, starting empty", "err", err)
	} else {
		live.Seed(seen)
		log.Info("presence seeded", "players", len(seen))
	}

	pages, err := legal.New(legal.Operator{Name: cfg.LegalName, Contact: cfg.SupportEmail})
	if err != nil {
		log.Error("legal pages", "err", err)
		os.Exit(1)
	}

	ready := &readiness{}
	ready.set(true)
	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpx.NewRouter(httpx.Deps{
			Legal:    pages,
			Store:    store,
			Log:      log,
			Health:   &gatedHealth{Checker: health.New(pool), ready: ready},
			Version:  version,
			Service:  svc,
			Verifier: signer,
			Presence: live,
			// The phone sends no Origin at all, which the websocket library
			// reads as same-origin; a browser build would name its host here.
			WSOrigins: cfg.AdminOrigins,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	// The admin surface listens separately. In production it binds to an
	// interface players cannot reach; nothing that can grant currency shares a
	// listener with the game API.
	// The admin service shares the boost store, so a boost created in the panel
	// is live on the next poll without a restart.
	adminSvc := &admin.Service{Pool: pool, Config: store, Boosts: boosts, Presence: live, Billing: svc, Game: &svc}
	// Moving a lord's clocks and counters is for testing, never for players.
	if !cfg.IsProd() {
		adminSvc.Dev = svc
	}

	// The live event stream. Its snapshot is the same board GET /live returns,
	// so a panel that has just connected and one that has been open for an hour
	// are looking at the same thing built by the same code.
	hub := adminstream.New(time.Now, log.With("surface", "stream"),
		func(c context.Context) (any, error) { return adminSvc.Live(c) })
	feed := admin.NewLiveFeed(adminSvc, hub)
	live.Attach(feed)

	adminSrv := &http.Server{
		Addr: cfg.AdminAddr,
		Handler: httpx.AdminRouter(adminSvc, log.With("surface", "admin"),
			&httpx.AdminStream{Hub: hub, Origins: cfg.AdminOrigins}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		// A listener with no idle timeout leaks connections. The websocket is
		// unaffected: its handler clears the deadlines on its own connection
		// before upgrading.
		IdleTimeout: 120 * time.Second,
	}

	// Unlike store.Watch and boosts.Poll above, this one is waited for: its last
	// act is to flush last_seen_at, and dropping that on every deploy would lose
	// up to thirty seconds of activity for every player online.
	presenceDone := make(chan struct{})
	go func() {
		defer close(presenceDone)
		if err := live.Run(ctx, presenceStore); err != nil {
			log.Error("presence stopped", "err", err)
		}
	}()

	// Enriching an arrival costs a query, so it happens here rather than in the
	// game middleware that observed it. A player's tap must never wait on an
	// admin's browser.
	feedDone := make(chan struct{})
	go func() {
		defer close(feedDone)
		if err := feed.Run(ctx); err != nil {
			log.Error("live feed stopped", "err", err)
		}
	}()

	errCh := make(chan error, 1)
	go func() {
		log.Info("admin listening", "addr", cfg.AdminAddr)
		if err := adminSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	go func() {
		log.Info("listening", "addr", cfg.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	// Fail readiness first and give the load balancer time to stop sending us
	// traffic, THEN stop accepting. Without this gap, in-flight requests are cut
	// off during every deploy.
	log.Info("shutting down: draining", "lag", cfg.ReadinessDrainLag)
	ready.set(false)
	time.Sleep(cfg.ReadinessDrainLag)

	shutCtx, shutCancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer shutCancel()
	// Before the admin server shuts down, not after: http.Server.Shutdown neither
	// closes hijacked connections nor waits for them, so a websocket left open
	// would have the panel believing it is connected to a process that is gone.
	hub.Close("server restarting")
	// The halls too: http.Server.Shutdown does not close hijacked connections,
	// so without this a deploy leaves every open hall talking to a process that
	// has gone.
	hall.Close("server restarting")
	_ = adminSrv.Shutdown(shutCtx)
	if err := srv.Shutdown(shutCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	select {
	case <-presenceDone:
	case <-shutCtx.Done():
		log.Warn("presence did not stop in time; last_seen_at may be up to a flush behind")
	}
	select {
	case <-feedDone:
	case <-shutCtx.Done():
	}
	log.Info("stopped cleanly")
	return nil
}
