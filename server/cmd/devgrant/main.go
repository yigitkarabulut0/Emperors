// Command devgrant sets a player's level and gold for local testing.
//
// Refuses to run when EMPERORS_ENV=prod. Granting currency is exactly the power
// an admin panel needs an audit trail for, so this deliberately stays a local
// tool rather than becoming an endpoint: features that reach late content
// (founding a kingdom needs level 20 and 250,000 gold) still need to be
// testable, but not through anything a running server exposes.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

func main() {
	user := flag.String("user", "", "username to grant to")
	level := flag.Int("level", 0, "set level (0 leaves it alone)")
	gold := flag.Int64("gold", 0, "set gold (0 leaves it alone)")
	flag.Parse()

	if err := run(*user, *level, *gold); err != nil {
		fmt.Fprintf(os.Stderr, "devgrant: %v\n", err)
		os.Exit(1)
	}
}

func run(user string, level int, gold int64) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if cfg.IsProd() {
		return fmt.Errorf("refusing to run against production")
	}
	if user == "" {
		return fmt.Errorf("-user is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	pool, err := db.NewAppPool(ctx, cfg.DatabaseURL, db.Options{
		MaxConns: 2, MinConns: 1,
		StatementTimeout: 15 * time.Second, LockTimeout: 5 * time.Second,
	})
	if err != nil {
		return err
	}
	defer pool.Close()

	q := sqlcdb.New(pool)
	p, err := q.GetPlayerByUsername(ctx, user)
	if err != nil {
		return fmt.Errorf("no such player %q: %w", user, err)
	}

	if level > 0 {
		if _, err := pool.Exec(ctx, `UPDATE app.players SET level = $2, xp = 0 WHERE id = $1`, p.ID, level); err != nil {
			return err
		}
	}
	if gold > 0 {
		if _, err := pool.Exec(ctx, `UPDATE app.players SET gold = $2 WHERE id = $1`, p.ID, gold); err != nil {
			return err
		}
		if _, err := pool.Exec(ctx,
			`INSERT INTO app.gold_ledger (player_id, delta, balance_after, reason)
			 VALUES ($1, $2, $2, 'dev_grant')`, p.ID, gold); err != nil {
			return err
		}
	}

	after, _ := q.GetPlayerByID(ctx, p.ID)
	fmt.Printf("%s: level %d, gold %d\n", user, after.Level, after.Gold)
	return nil
}
