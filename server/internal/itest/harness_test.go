//go:build integration

// Package itest runs the service layer against a real Postgres.
//
// Everything else in the server is tested without a database: the pure game
// code directly, and the service layer only up to its first query. That leaves
// the rules that live in SQL -- a guard in a WHERE, a debt repaid inside an
// UPDATE, a savepoint that keeps a transaction alive -- tested by reading the
// statement's text. This package runs them.
//
//	EMPERORS_TEST_DATABASE_URL=postgres://emperors@127.0.0.1:5544/postgres?sslmode=disable \
//	  go test -tags integration -count=1 ./internal/itest/...
//
// The URL names any database on a disposable server (never production). Each
// run creates its own database, migrates it with the embedded migrations, and
// drops it afterwards. Without the variable the package skips.
package itest

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	dbfs "github.com/yigitkarabulut0/emperors/server/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

var pool *pgxpool.Pool

func TestMain(m *testing.M) {
	base := os.Getenv("EMPERORS_TEST_DATABASE_URL")
	if base == "" {
		fmt.Println("itest: EMPERORS_TEST_DATABASE_URL is not set; skipping")
		os.Exit(0)
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		fmt.Fprintln(os.Stderr, "itest: connect:", err)
		os.Exit(1)
	}
	name := fmt.Sprintf("emperors_it_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		fmt.Fprintln(os.Stderr, "itest: create database:", err)
		os.Exit(1)
	}
	dsn, err := withDatabase(base, name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "itest:", err)
		os.Exit(1)
	}

	code := func() int {
		if err := migrate(dsn); err != nil {
			fmt.Fprintln(os.Stderr, "itest: migrate:", err)
			return 1
		}
		pool, err = pgxpool.New(ctx, dsn)
		if err != nil {
			fmt.Fprintln(os.Stderr, "itest: pool:", err)
			return 1
		}
		defer pool.Close()
		return m.Run()
	}()

	if _, err := admin.Exec(ctx, "DROP DATABASE "+name+" WITH (FORCE)"); err != nil {
		fmt.Fprintln(os.Stderr, "itest: drop database:", err)
	}
	_ = admin.Close(ctx)
	os.Exit(code)
}

func withDatabase(base, name string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", fmt.Errorf("EMPERORS_TEST_DATABASE_URL: %w", err)
	}
	u.Path = "/" + name
	return u.String(), nil
}

func migrate(dsn string) error {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	goose.SetBaseFS(dbfs.Migrations)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	return goose.Up(db, "migrations")
}

// world is one test's view of the game: the real service over the test
// database, with a clock the test can move.
type world struct {
	t   *testing.T
	ctx context.Context
	now time.Time
	d   service.Deps
	q   *sqlcdb.Queries
}

func newWorld(t *testing.T) *world {
	t.Helper()
	cfg, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, ctx: context.Background(), now: time.Now().UTC(), q: sqlcdb.New(pool)}
	w.d = service.Deps{
		Pool: pool, Config: cfg, Now: func() time.Time { return w.now },
		ShopSecret: []byte("itest-shop-secret"),
	}
	t.Cleanup(func() { reconcileDiamonds(t) })
	return w
}

// player creates a lord at a level, with gold, and a full-enough pool.
func (w *world) player(level int32, gold int64) sqlcdb.AppPlayer {
	w.t.Helper()
	name := "it" + uuid.NewString()[:12]
	p, err := w.q.CreatePlayer(w.ctx, sqlcdb.CreatePlayerParams{
		Username: name, DisplayName: name, EnergyMilli: 300_000, ResetOffsetMinutes: 0,
	})
	if err != nil {
		w.t.Fatal(err)
	}
	if _, err := pool.Exec(w.ctx,
		`UPDATE app.players SET level = $2, gold = $3, energy_updated_at = $4, storehouse_at = $4 WHERE id = $1`,
		p.ID, level, gold, w.now); err != nil {
		w.t.Fatal(err)
	}
	return w.reload(p.ID)
}

func (w *world) reload(id uuid.UUID) sqlcdb.AppPlayer {
	w.t.Helper()
	p, err := w.q.GetPlayerByID(w.ctx, id)
	if err != nil {
		w.t.Fatal(err)
	}
	return p
}

func (w *world) exec(sql string, args ...any) {
	w.t.Helper()
	if _, err := pool.Exec(w.ctx, sql, args...); err != nil {
		w.t.Fatal(err)
	}
}

// reconcileDiamonds proves every balance against its ledger: the rows for a
// player sum to what they hold, and the newest row's debt is what they owe.
//
// Run after every test, over every player the tests have touched. A write that
// moved diamonds without a ledger row fails here even if no test looked for it.
func reconcileDiamonds(t *testing.T) {
	t.Helper()
	rows, err := pool.Query(context.Background(), `
		SELECT p.id, p.diamonds, coalesce(l.total, 0), p.diamond_debt,
		       coalesce((SELECT debt_after FROM app.diamond_ledger x
		                 WHERE x.player_id = p.id ORDER BY x.id DESC LIMIT 1), 0)
		FROM app.players p
		LEFT JOIN (SELECT player_id, sum(delta) AS total FROM app.diamond_ledger GROUP BY player_id) l
		       ON l.player_id = p.id
		WHERE p.diamonds <> coalesce(l.total, 0)
		   OR p.diamond_debt <> coalesce((SELECT debt_after FROM app.diamond_ledger x
		                                  WHERE x.player_id = p.id ORDER BY x.id DESC LIMIT 1), 0)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var held, summed, owed, lastDebt int64
		if err := rows.Scan(&id, &held, &summed, &owed, &lastDebt); err != nil {
			t.Fatal(err)
		}
		t.Errorf("diamond ledger does not reconcile for %s: holds %d, ledger sums %d; owes %d, ledger says %d",
			id, held, summed, owed, lastDebt)
	}
}
