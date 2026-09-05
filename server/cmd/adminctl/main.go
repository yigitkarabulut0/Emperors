// Command adminctl bootstraps the admin surface: create the first user, and
// publish the embedded seed as balance version 1.
//
// Creating admins is a local command rather than an endpoint on purpose. An
// account that can grant currency and ban players should not be creatable by
// anything reachable over the network, however well authenticated.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func main() {
	cmd := flag.String("cmd", "", "create-admin | seed-balance")
	user := flag.String("user", "", "admin username")
	pass := flag.String("pass", "", "admin password")
	role := flag.String("role", "owner", "owner | designer | moderator | analyst")
	flag.Parse()

	if err := run(*cmd, *user, *pass, *role); err != nil {
		fmt.Fprintf(os.Stderr, "adminctl: %v\n", err)
		os.Exit(1)
	}
}

func run(cmd, user, pass, role string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	pool, err := db.NewAppPool(ctx, cfg.DatabaseURL, db.Options{
		MaxConns: 2, MinConns: 1,
		StatementTimeout: 20 * time.Second, LockTimeout: 5 * time.Second,
	})
	if err != nil {
		return err
	}
	defer pool.Close()
	q := sqlcdb.New(pool)

	switch cmd {
	case "create-admin":
		if user == "" || pass == "" {
			return fmt.Errorf("-user and -pass are required")
		}
		hash, err := auth.HashPassword(pass)
		if err != nil {
			return err
		}
		u, err := q.CreateAdminUser(ctx, sqlcdb.CreateAdminUserParams{
			Username: user, PasswordHash: hash, Role: role,
		})
		if err != nil {
			return fmt.Errorf("create admin: %w", err)
		}
		fmt.Printf("created admin %q with role %s\n", u.Username, u.Role)
		return nil

	case "seed-balance":
		n, err := q.CountBalanceVersions(ctx)
		if err != nil {
			return err
		}
		if n > 0 {
			fmt.Printf("%d balance version(s) already exist; nothing to do\n", n)
			return nil
		}
		seed, err := gameconfig.LoadSeed()
		if err != nil {
			return err
		}
		svc := &admin.Service{
			Pool:   pool,
			Config: gameconfig.NewStore(seed, admin.BalanceLoader{Pool: pool}, nil),
		}
		v, err := svc.Publish(ctx, seed.Doc(), "initial seed", "system")
		if err != nil {
			return err
		}
		fmt.Printf("published balance version %d (%d bytes)\n", v.ID, v.Bytes)
		return nil
	}
	return fmt.Errorf("unknown -cmd %q", cmd)
}
