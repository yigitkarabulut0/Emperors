package main

import (
	"errors"
	"net/http"
	"sync/atomic"

	"github.com/yigitkarabulut0/emperors/server/internal/health"
)

// readiness lets shutdown flip /readyz to 503 before the listener closes.
type readiness struct{ ok atomic.Bool }

func (r *readiness) set(v bool) { r.ok.Store(v) }
func (r *readiness) get() bool  { return r.ok.Load() }

// gatedHealth reports "not ready" during drain even though the database is
// still perfectly reachable.
type gatedHealth struct {
	*health.Checker
	ready *readiness
}

var errDraining = errors.New("server is draining")

func (g *gatedHealth) Ping(req *http.Request) error {
	if !g.ready.get() {
		return errDraining
	}
	return g.Checker.Ping(req)
}
