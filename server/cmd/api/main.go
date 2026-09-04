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

	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/health"
	"github.com/yigitkarabulut0/emperors/server/internal/httpx"
	"github.com/yigitkarabulut0/emperors/server/internal/obs"
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

	ready := &readiness{}
	ready.set(true)
	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpx.NewRouter(httpx.Deps{
			Log:     log,
			Health:  &gatedHealth{Checker: health.New(pool), ready: ready},
			Version: version,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	errCh := make(chan error, 1)
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
	if err := srv.Shutdown(shutCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	log.Info("stopped cleanly")
	return nil
}
