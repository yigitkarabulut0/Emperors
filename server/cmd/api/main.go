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
	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/health"
	"github.com/yigitkarabulut0/emperors/server/internal/httpx"
	"github.com/yigitkarabulut0/emperors/server/internal/obs"
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
	adminSvc := &admin.Service{Pool: pool, Config: store, Boosts: boosts}
	adminSrv := &http.Server{
		Addr:              cfg.AdminAddr,
		Handler:           httpx.AdminRouter(adminSvc, log.With("surface", "admin")),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
	}

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
	_ = adminSrv.Shutdown(shutCtx)
	if err := srv.Shutdown(shutCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	log.Info("stopped cleanly")
	return nil
}
