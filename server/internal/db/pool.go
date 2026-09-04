// Package db owns Postgres connectivity.
//
// Two pools, deliberately:
//
//   - App runs against Neon's POOLED endpoint (PgBouncer, transaction mode).
//     pgx v5's default QueryExecModeCacheStatement works there because PgBouncer
//     1.21+ supports protocol-level prepared statements; we keep an env escape
//     hatch in case that ever regresses.
//   - Direct runs against Neon's UNPOOLED endpoint and is used by migrations and
//     anything that needs session state. Advisory locks held across statements —
//     which goose relies on — cannot work through transaction-mode pooling.
//
// Statement and lock timeouts are set as connection RuntimeParams on the app
// pool ONLY. Setting them with ALTER ROLE would also apply them to migrations,
// where a long CREATE INDEX legitimately exceeds them.
package db

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Options struct {
	MaxConns         int32
	MinConns         int32
	StatementTimeout time.Duration
	LockTimeout      time.Duration
}

// NewAppPool builds the request-traffic pool against the pooled endpoint.
func NewAppPool(ctx context.Context, dsn string, o Options) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse pooled DSN: %w", err)
	}

	cfg.MaxConns = o.MaxConns
	cfg.MinConns = o.MinConns
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second

	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = msString(o.StatementTimeout)
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = msString(o.LockTimeout)
	cfg.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = msString(15 * time.Second)
	cfg.ConnConfig.RuntimeParams["application_name"] = "emperors-api"

	// Escape hatch: EMPERORS_PGX_SIMPLE_PROTOCOL=1 falls back to the exec mode
	// that works against any pooler, at the cost of losing statement caching.
	if os.Getenv("EMPERORS_PGX_SIMPLE_PROTOCOL") == "1" {
		cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pooled pool: %w", err)
	}
	return pool, nil
}

// NewDirectConn opens a single connection to the unpooled endpoint. Callers own
// closing it. Used by migrations and by session-state work.
func NewDirectConn(ctx context.Context, dsn string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse direct DSN: %w", err)
	}
	if cfg.RuntimeParams == nil {
		cfg.RuntimeParams = map[string]string{}
	}
	cfg.RuntimeParams["application_name"] = "emperors-migrate"
	return pgx.ConnectConfig(ctx, cfg)
}

func msString(d time.Duration) string {
	return fmt.Sprintf("%d", d.Milliseconds())
}
