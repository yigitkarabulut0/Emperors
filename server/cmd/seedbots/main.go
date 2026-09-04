// Command seedbots populates the Attack tab with plausible opponents.
//
// Without them the core PvP loop is empty on day one — exactly when retention
// matters most — and the very first player to install has nobody to fight. The
// bots are not labelled in the UI, but they ARE flagged in the database, so the
// admin panel can always report what fraction of fights were against them and
// the ratio can be decayed to zero as the real population grows.
package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/config"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var firstNames = []string{
	"Aldric", "Bertran", "Cedric", "Dunstan", "Edmund", "Falk", "Godwin", "Hakon",
	"Ivar", "Jorund", "Kestrel", "Lothar", "Merrick", "Norbert", "Osric", "Perrin",
	"Quill", "Roderic", "Sigmund", "Tybalt", "Ulric", "Verdan", "Wulfric", "Yorick",
}
var epithets = []string{
	"the Bold", "of Ashford", "the Grim", "Ironhand", "of Blackmoor", "the Lame",
	"Redcloak", "the Younger", "of Thornvale", "Stonefist", "the Patient", "Greymane",
}

func main() {
	count := flag.Int("count", 40, "how many bots to ensure exist")
	flag.Parse()

	if err := run(*count); err != nil {
		fmt.Fprintf(os.Stderr, "seedbots: %v\n", err)
		os.Exit(1)
	}
}

func run(want int) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	bundle, err := gameconfig.LoadSeed()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	pool, err := db.NewAppPool(ctx, cfg.DatabaseURL, db.Options{
		MaxConns: 4, MinConns: 1,
		StatementTimeout: 30 * time.Second, LockTimeout: 10 * time.Second,
	})
	if err != nil {
		return err
	}
	defer pool.Close()

	q := sqlcdb.New(pool)
	have, err := q.CountBots(ctx)
	if err != nil {
		return fmt.Errorf("count bots: %w", err)
	}
	if int(have) >= want {
		fmt.Printf("%d bots already present, nothing to do\n", have)
		return nil
	}

	// Deterministic so re-running produces the same roster rather than a new
	// crowd of near-duplicates.
	rng := rand.New(rand.NewPCG(0x5EED, 0xB075))
	created := 0

	for i := int(have); i < want; i++ {
		level := 1 + i*3/2 // spread across the level band players actually occupy
		if level > bundle.Progression.LevelCap {
			level = bundle.Progression.LevelCap
		}
		name := fmt.Sprintf("%s %s", firstNames[i%len(firstNames)], epithets[(i/len(firstNames))%len(epithets)])
		username := fmt.Sprintf("bot_%03d", i)

		// Roughly what a real player of that level would have allocated.
		pts := int32(level - 1)
		slots := int32(min(level/4+1, bundle.Soldiers.MaxSlots))

		p, err := q.CreateBot(ctx, sqlcdb.CreateBotParams{
			Username: username, DisplayName: name, Level: int32(level),
			Gold:         int64(200 + level*180),
			SoldierSlots: slots,
			StatAttack:   pts / 2, StatDefense: pts - pts/2,
		})
		if err != nil {
			return fmt.Errorf("create %s: %w", username, err)
		}

		for slot := int32(1); slot <= slots; slot++ {
			typeID := "peasant"
			switch {
			case level >= 30:
				typeID = "gladiator"
			case level >= 12:
				typeID = "mercenary"
			}
			t := bundle.SoldierType(typeID)
			tier := items.RollTier(bundle, rng, t.Weights, t.LuckCoef, level)
			if _, err := q.UpsertSoldier(ctx, sqlcdb.UpsertSoldierParams{
				PlayerID: p.ID, SlotIndex: slot, TypeID: typeID, Tier: tier,
				Level: int32(level), Name: t.Name, RolledConfigVersion: int32(bundle.Version),
			}); err != nil {
				return fmt.Errorf("soldier for %s: %w", username, err)
			}
		}
		created++
	}

	fmt.Printf("created %d bots (now %d total)\n", created, int(have)+created)
	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
