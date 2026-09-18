package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
)

// Dev tools, for a server that is not production: cmd/api hands them to the
// panel only there, and the panel refuses them without. They exist so a timer
// (a storehouse, a calendar, a four-hour chest) can be tried in a minute
// instead of a day, and a counter (a weekly task, an achievement) without
// playing a week.
//
// Each moves one lord, never the server's clock or anyone else.

// ErrDevRange is a dev request out of its bounds.
var ErrDevRange = errors.New("out of range")

// DevWarpMaxHours bounds one time warp: a month, as far as a lord is ever away
// for anything here to have happened.
const DevWarpMaxHours = 24 * 31

// DevTimeWarp moves a lord's clocks hours into the past, as if they had been
// away that long: energy and the storehouse fill for it; shields, boosts,
// offers, letters, cooldowns and revenge windows run out that much sooner; and
// the day markers (the day's reward, refills, rerolls, the Stipend and Royal
// Favour's gift, the day's deals) move back by its whole days.
func (d Deps) DevTimeWarp(ctx context.Context, playerID uuid.UUID, hours int) error {
	if hours < 1 || hours > DevWarpMaxHours {
		return fmt.Errorf("%w: warp between 1 and %d hours", ErrDevRange, DevWarpMaxHours)
	}
	h := int32(hours)
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		if _, err := q.LockPlayer(ctx, playerID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return err
		}
		for name, warp := range map[string]func() error{
			"clocks":    func() error { return q.WarpPlayerClocks(ctx, sqlcdb.WarpPlayerClocksParams{ID: playerID, Hours: h}) },
			"offers":    func() error { return q.WarpOffers(ctx, sqlcdb.WarpOffersParams{ID: playerID, Hours: h}) },
			"boosts":    func() error { return q.WarpPlayerBoosts(ctx, sqlcdb.WarpPlayerBoostsParams{ID: playerID, Hours: h}) },
			"cosmetics": func() error { return q.WarpCosmetics(ctx, sqlcdb.WarpCosmeticsParams{ID: playerID, Hours: h}) },
			"mail":      func() error { return q.WarpMail(ctx, sqlcdb.WarpMailParams{ID: playerID, Hours: h}) },
			"cooldowns": func() error { return q.WarpCooldowns(ctx, sqlcdb.WarpCooldownsParams{ID: playerID, Hours: h}) },
			"revenge":   func() error { return q.WarpRevenge(ctx, sqlcdb.WarpRevengeParams{ID: playerID, Hours: h}) },
			"deals":     func() error { return q.WarpDeals(ctx, sqlcdb.WarpDealsParams{ID: playerID, Hours: h}) },
		} {
			if err := warp(); err != nil {
				return fmt.Errorf("warp %s: %w", name, err)
			}
		}
		return nil
	})
}

// DevAddDeeds counts n of a deed for a lord, in every scope it is kept over,
// as if they had done them now.
func (d Deps) DevAddDeeds(ctx context.Context, playerID uuid.UUID, kind string, n int64) error {
	if !deeds.Known(deeds.Kind(kind)) {
		return fmt.Errorf("%w: no deed is called %q", ErrDevRange, kind)
	}
	if n < 1 || n > 1_000_000_000 {
		return fmt.Errorf("%w: count between 1 and a billion", ErrDevRange)
	}
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	// Where a played deed would land: every scope, the season's and the
	// running festival's, and their points (the day's quests aside).
	return d.countDeeds(ctx, q, p, deeds.Deeds{deeds.Kind(kind): n}, d.Now())
}

// DevRunJob runs one scheduled job now, outside its schedule and its claim, at
// the server's time.
func (d Deps) DevRunJob(ctx context.Context, name string) error {
	for _, j := range ScheduledJobs() {
		if j.Name == name {
			return j.Run(ctx, d, d.Now().UTC())
		}
	}
	return fmt.Errorf("%w: no job is called %q", ErrDevRange, name)
}

// DevRestartGuide puts a lord back at the guide's first step, as a new lord
// begins it: to walk the first ten minutes again with an account that has them
// behind it.
func (d Deps) DevRestartGuide(ctx context.Context, playerID uuid.UUID) error {
	n, err := sqlcdb.New(d.Pool).RestartGuide(ctx, playerID)
	if err != nil {
		return fmt.Errorf("restart the guide: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
