package service

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// softStep runs a side effect that is worth doing but not worth failing the
// action it rides on -- a quest tick, a progress counter -- inside a savepoint.
//
// Swallowing the error is not enough on its own, which is what the quest bump
// did for months. In Postgres a statement that fails inside a transaction
// aborts the WHOLE transaction: every later statement is refused and the COMMIT
// comes back as a rollback. So a "non-fatal" quest bump that hit an error took
// the collect, the raid or the purchase down with it as a 500. A savepoint is
// the only thing that lets a failed statement be undone on its own: the side
// effect is rolled back to the savepoint and the outer transaction carries on as
// if it had never been tried.
//
// The failure is logged, never returned. fn must use the Queries it is handed,
// which are bound to the savepoint; writing through the outer ones would put the
// statement outside the savepoint's protection.
func (d Deps) softStep(ctx context.Context, tx pgx.Tx, what string, fn func(q *sqlcdb.Queries) error) {
	sp, err := tx.Begin(ctx)
	if err != nil {
		d.logSoftStep(what, err)
		return
	}
	if err := fn(sqlcdb.New(sp)); err != nil {
		// Rolls back to the savepoint only. The outer transaction is usable again.
		_ = sp.Rollback(ctx)
		d.logSoftStep(what, err)
		return
	}
	if err := sp.Commit(ctx); err != nil { // RELEASE SAVEPOINT
		d.logSoftStep(what, err)
	}
}

// logSoftStep records a side effect that was dropped.
//
// Swallowed, but not silently: if these ever appear in volume a counter is
// drifting and whatever reads it -- the dailies, a weekly board -- will quietly
// stop completing.
func (d Deps) logSoftStep(what string, err error) {
	if d.Log != nil {
		d.Log.Warn("side effect not recorded", "what", what, "err", err)
	}
}
