// Package config loads and validates all runtime configuration from the
// environment. It fails fast: a server that starts with a bad config and
// discovers it on the first request is worse than one that never starts.
package config

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Env  string // dev | staging | prod
	Addr string // listen address, e.g. ":8080"

	// DatabaseURL is Neon's POOLED endpoint (PgBouncer, transaction mode) and
	// serves all request traffic. DatabaseURLDirect is the unpooled endpoint and
	// is used only by migrations and anything needing session state — PgBouncer
	// in transaction mode cannot support advisory locks held across statements,
	// which is exactly what goose needs.
	DatabaseURL       string
	DatabaseURLDirect string

	MaxConns          int32
	MinConns          int32
	StatementTimeout  time.Duration
	LockTimeout       time.Duration
	ShutdownGrace     time.Duration
	ReadinessDrainLag time.Duration

	LogLevel string

	// TokenSeed is the 32-byte Ed25519 seed for access tokens. It must be stable:
	// changing it invalidates every access token and logs everyone out.
	TokenSeed []byte
}

func Load() (*Config, error) {
	c := &Config{
		Env:               env("EMPERORS_ENV", "dev"),
		Addr:              env("EMPERORS_ADDR", ":8080"),
		DatabaseURL:       os.Getenv("DATABASE_URL"),
		DatabaseURLDirect: os.Getenv("DATABASE_URL_DIRECT"),
		LogLevel:          env("EMPERORS_LOG_LEVEL", "info"),
	}

	if seed := os.Getenv("EMPERORS_TOKEN_SEED"); seed != "" {
		raw, decErr := base64.StdEncoding.DecodeString(seed)
		if decErr != nil {
			return nil, fmt.Errorf("EMPERORS_TOKEN_SEED must be base64: %w", decErr)
		}
		c.TokenSeed = raw
	}

	var err error
	if c.MaxConns, err = envInt32("EMPERORS_DB_MAX_CONNS", 10); err != nil {
		return nil, err
	}
	if c.MinConns, err = envInt32("EMPERORS_DB_MIN_CONNS", 2); err != nil {
		return nil, err
	}
	if c.StatementTimeout, err = envDur("EMPERORS_STATEMENT_TIMEOUT", 8*time.Second); err != nil {
		return nil, err
	}
	if c.LockTimeout, err = envDur("EMPERORS_LOCK_TIMEOUT", 3*time.Second); err != nil {
		return nil, err
	}
	if c.ShutdownGrace, err = envDur("EMPERORS_SHUTDOWN_GRACE", 20*time.Second); err != nil {
		return nil, err
	}
	if c.ReadinessDrainLag, err = envDur("EMPERORS_READINESS_DRAIN_LAG", 3*time.Second); err != nil {
		return nil, err
	}

	return c, c.validate()
}

func (c *Config) validate() error {
	var problems []string
	if c.DatabaseURL == "" {
		problems = append(problems, "DATABASE_URL is required (Neon pooled endpoint)")
	}
	// Fall back to the pooled DSN so local development works with one variable,
	// but say so loudly in prod where migrations must not run through PgBouncer.
	if c.DatabaseURLDirect == "" {
		if c.Env == "prod" {
			problems = append(problems, "DATABASE_URL_DIRECT is required in prod (Neon unpooled endpoint, for migrations)")
		}
		c.DatabaseURLDirect = c.DatabaseURL
	}
	switch {
	case len(c.TokenSeed) == 0 && c.Env == "prod":
		problems = append(problems, "EMPERORS_TOKEN_SEED is required in prod (base64 of 32 random bytes)")
	case len(c.TokenSeed) == 0:
		// Dev convenience: a random seed per boot. Restarting logs you out, which
		// is fine locally and would be unacceptable in production.
		c.TokenSeed = make([]byte, 32)
		if _, err := rand.Read(c.TokenSeed); err != nil {
			problems = append(problems, "could not generate a development token seed")
		}
	case len(c.TokenSeed) != 32:
		problems = append(problems, fmt.Sprintf("EMPERORS_TOKEN_SEED must decode to 32 bytes, got %d", len(c.TokenSeed)))
	}

	if c.MinConns > c.MaxConns {
		problems = append(problems, "EMPERORS_DB_MIN_CONNS must not exceed EMPERORS_DB_MAX_CONNS")
	}
	switch c.Env {
	case "dev", "staging", "prod":
	default:
		problems = append(problems, "EMPERORS_ENV must be dev, staging or prod")
	}
	if len(problems) > 0 {
		return fmt.Errorf("invalid configuration:\n  - %s", strings.Join(problems, "\n  - "))
	}
	return nil
}

// IsProd reports whether this is the production environment.
func (c *Config) IsProd() bool { return c.Env == "prod" }

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt32(k string, def int32) (int32, error) {
	v := os.Getenv(k)
	if v == "" {
		return def, nil
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", k, err)
	}
	return int32(n), nil
}

func envDur(k string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(k)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", k, err)
	}
	return d, nil
}
