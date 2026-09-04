package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// maxTxAttempts bounds the retry loop. Deadlocks and serialization failures are
// transient by definition; anything that fails three times is a real bug and
// should surface rather than spin.
const maxTxAttempts = 3

// InTx runs fn inside a transaction, committing on success and rolling back on
// any error or panic.
//
// It retries only on the two Postgres errors that are genuinely transient:
// 40001 serialization_failure and 40P01 deadlock_detected. Retrying anything
// else — a constraint violation, say — would just repeat the same failure while
// holding locks.
//
// fn MUST be idempotent with respect to anything outside the transaction, since
// it can run more than once. Everything it does inside the transaction is rolled
// back between attempts, so database work is safe; sending an email is not.
func InTx(ctx context.Context, pool *pgxpool.Pool, fn func(pgx.Tx) error) error {
	var err error
	for attempt := 1; attempt <= maxTxAttempts; attempt++ {
		err = runTx(ctx, pool, fn)
		if err == nil {
			return nil
		}
		if !isRetryable(err) {
			return err
		}
		// Brief backoff so two contending transactions do not re-collide
		// immediately in lockstep.
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * 10 * time.Millisecond):
		}
	}
	return fmt.Errorf("transaction failed after %d attempts: %w", maxTxAttempts, err)
}

func runTx(ctx context.Context, pool *pgxpool.Pool, fn func(pgx.Tx) error) (err error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(context.WithoutCancel(ctx))
			panic(p)
		}
		if err != nil {
			// WithoutCancel: if the request context is already dead, the rollback
			// still has to reach the server or the transaction lingers holding locks.
			_ = tx.Rollback(context.WithoutCancel(ctx))
		}
	}()

	if err = fn(tx); err != nil {
		return err
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

func isRetryable(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	switch pgErr.Code {
	case "40001", "40P01": // serialization_failure, deadlock_detected
		return true
	}
	return false
}

// IsUniqueViolation reports whether err is a duplicate-key error, optionally for
// a specific constraint. Callers use it to turn a race into a clean "that name
// is taken" rather than a 500.
func IsUniqueViolation(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return false
	}
	return constraint == "" || pgErr.ConstraintName == constraint
}
