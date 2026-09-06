// Package config loads and validates all runtime configuration from the
// environment. It fails fast: a server that starts with a bad config and
// discovers it on the first request is worse than one that never starts.
package config

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Env       string // dev | staging | prod
	Addr      string // game API listen address
	AdminAddr string // admin API listen address; separate so it can be firewalled off

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

	// AdminOrigins is the allowlist for admin websocket handshakes.
	//
	// Websockets are exempt from CORS, so the browser will happily connect a
	// page on any origin to this server and the only thing standing between an
	// attacker's page and a live feed of who is playing is this check. Empty
	// means same-origin only, which is the right production value once the panel
	// and the stream are served from one host.
	AdminOrigins []string

	// ShopSecret seeds the deterministic shop roll. It must be stable and secret:
	// stable because changing it reshuffles every player's current offers
	// mid-window, and secret because anyone who knows it can predict which
	// five-minute window will contain a legendary.
	ShopSecret []byte
}

func Load() (*Config, error) {
	c := &Config{
		Env:               env("EMPERORS_ENV", "dev"),
		Addr:              env("EMPERORS_ADDR", ":8080"),
		AdminAddr:         env("EMPERORS_ADMIN_ADDR", ":8081"),
		DatabaseURL:       os.Getenv("DATABASE_URL"),
		DatabaseURLDirect: os.Getenv("DATABASE_URL_DIRECT"),
		LogLevel:          env("EMPERORS_LOG_LEVEL", "info"),
		AdminOrigins:      splitList(env("EMPERORS_ADMIN_ORIGINS", "localhost:3000,127.0.0.1:3000")),
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

// devSecret returns a stable 32-byte secret for local development, generating
// and caching it on first use.
//
// NEVER reached in prod: validate() requires the environment variable there, so
// this cannot silently become the production key. The file sits beside the repo
// rather than in it, and is created 0600.
func devSecret(name string) ([]byte, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}
	dir = filepath.Join(dir, "emperors-dev")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, name)

	if raw, err := os.ReadFile(path); err == nil && len(raw) == 32 {
		return raw, nil
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, secret, 0o600); err != nil {
		return nil, err
	}
	return secret, nil
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
		// Dev convenience: generate one, but KEEP it. A fresh seed per boot
		// invalidates every outstanding access token, and a restart during
		// development happens constantly -- it was signing the player out mid-play
		// every time the server came back.
		seed, err := devSecret("token_seed")
		if err != nil {
			problems = append(problems, "could not obtain a development token seed: "+err.Error())
		}
		c.TokenSeed = seed
	case len(c.TokenSeed) != 32:
		problems = append(problems, fmt.Sprintf("EMPERORS_TOKEN_SEED must decode to 32 bytes, got %d", len(c.TokenSeed)))
	}

	// A wildcard origin would let any page on the internet open a live feed of
	// who is playing, so it is refused outright rather than warned about.
	for _, o := range c.AdminOrigins {
		if strings.Contains(o, "*") && c.Env == "prod" {
			problems = append(problems, "EMPERORS_ADMIN_ORIGINS must not contain a wildcard in prod")
		}
	}

	if seed := os.Getenv("EMPERORS_SHOP_SECRET"); seed != "" {
		raw, decErr := base64.StdEncoding.DecodeString(seed)
		if decErr != nil {
			problems = append(problems, "EMPERORS_SHOP_SECRET must be base64")
		} else {
			c.ShopSecret = raw
		}
	}
	switch {
	case len(c.ShopSecret) == 0 && c.Env == "prod":
		problems = append(problems, "EMPERORS_SHOP_SECRET is required in prod (base64 of 32 random bytes)")
	case len(c.ShopSecret) == 0:
		// Same reasoning, plus one of its own: a fresh shop secret reshuffles
		// every player's current offers mid-window, so a restart could snatch back
		// an offer someone was about to buy.
		secret, err := devSecret("shop_secret")
		if err != nil {
			problems = append(problems, "could not obtain a development shop secret: "+err.Error())
		}
		c.ShopSecret = secret
	case len(c.ShopSecret) < 16:
		problems = append(problems, "EMPERORS_SHOP_SECRET must decode to at least 16 bytes")
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

// splitList parses a comma-separated environment value, dropping blanks.
func splitList(v string) []string {
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
