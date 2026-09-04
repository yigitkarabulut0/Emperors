// Command migrate applies database migrations.
//
// It runs against Neon's DIRECT (unpooled) endpoint on purpose: goose takes a
// session-level advisory lock to serialise concurrent migrators, and a
// transaction-mode pooler cannot hold one across statements. It is also a
// separate binary from the API so that deploying the API never silently
// migrates production.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	dbfs "github.com/yigitkarabulut0/emperors/server/db"
	"github.com/yigitkarabulut0/emperors/server/internal/config"
)

func main() {
	cmd := flag.String("cmd", "up", "goose command: up, down, status, version, redo")
	flag.Parse()

	if err := run(*cmd); err != nil {
		fmt.Fprintf(os.Stderr, "migrate: %v\n", err)
		os.Exit(1)
	}
}

func run(cmd string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// database/sql over pgx: goose needs a *sql.DB, and this is the supported
	// bridge. Note this uses the DIRECT DSN, not the pooled one.
	sqlDB, err := sql.Open("pgx", cfg.DatabaseURLDirect)
	if err != nil {
		return fmt.Errorf("open direct connection: %w", err)
	}
	defer sqlDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	if err := sqlDB.PingContext(ctx); err != nil {
		return fmt.Errorf("ping direct endpoint: %w", err)
	}

	goose.SetBaseFS(dbfs.Migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}

	switch cmd {
	case "up":
		err = goose.UpContext(ctx, sqlDB, "migrations")
	case "down":
		err = goose.DownContext(ctx, sqlDB, "migrations")
	case "redo":
		err = goose.RedoContext(ctx, sqlDB, "migrations")
	case "status":
		err = goose.StatusContext(ctx, sqlDB, "migrations")
	case "version":
		err = goose.VersionContext(ctx, sqlDB, "migrations")
	default:
		return errors.New("unknown command: " + cmd)
	}
	return err
}
