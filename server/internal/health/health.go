// Package health answers "is the database there, and what does it say".
package health

import (
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Checker struct{ Pool *pgxpool.Pool }

func New(p *pgxpool.Pool) *Checker { return &Checker{Pool: p} }

func (c *Checker) Ping(r *http.Request) error {
	ctx, cancel := contextWithTimeout(r, 2*time.Second)
	defer cancel()
	return c.Pool.Ping(ctx)
}

// Motto reads a row written by migration 00001. It is the M0 proof: if the
// phone renders this string, then TLS, the VPS, the Go binary, the Neon pooled
// endpoint and the migration chain are all working.
func (c *Checker) Motto(r *http.Request) (string, string, error) {
	ctx, cancel := contextWithTimeout(r, 3*time.Second)
	defer cancel()

	var motto string
	var now time.Time
	err := c.Pool.QueryRow(ctx,
		`SELECT value, now() FROM app.server_info WHERE key = 'motto'`,
	).Scan(&motto, &now)
	if err != nil {
		return "", "", err
	}
	return motto, now.UTC().Format(time.RFC3339), nil
}
