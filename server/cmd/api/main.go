// Command api is the Emperors game server: one stateless binary, authoritative
// for every number in the game.
package main

import (
	"context"
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
	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/health"
	"github.com/yigitkarabulut0/emperors/server/internal/httpx"
	"github.com/yigitkarabulut0/emperors/server/internal/obs"
	"github.com/yigitkarabulut0/emperors/server/internal/presence"
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

	svc := service.Deps{
		Pool: pool, Config: bundle, Signer: signer, Now: time.Now,
		ShopSecret: cfg.ShopSecret,
		Boosts:     boosts,
	}

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

	ready := &readiness{}
	ready.set(true)
	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpx.NewRouter(httpx.Deps{
			Store:    store,
			Log:      log,
			Health:   &gatedHealth{Checker: health.New(pool), ready: ready},
			Version:  version,
			Service:  svc,
			Verifier: signer,
			Presence: live,
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
	adminSvc := &admin.Service{Pool: pool, Config: store, Boosts: boosts, Presence: live}

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
