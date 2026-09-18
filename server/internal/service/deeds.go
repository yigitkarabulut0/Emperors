package service

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
)

// recordDeeds is where every action reports what it did.
//
// Today's quests keep their four columns; every other counter -- weekly tasks,
// the boards, a festival's tasks, achievements -- reads app.player_deeds, which
// this writes for the player's lifetime, their local week, the UTC week, and
// the season and festival running, in one statement. The same deeds earn the
// Royal Charter's points and the running festival's, each under its day's cap.
//
// Inside the action's own transaction, so nothing is counted that was rolled
// back; and inside a savepoint, so a counter that cannot be written costs a
// tick, never the action.
func (d Deps) recordDeeds(ctx context.Context, tx pgx.Tx, p sqlcdb.AppPlayer, dd deeds.Deeds) {
	d.softStep(ctx, tx, "deeds", func(q *sqlcdb.Queries) error {
		now := d.Now()
		if questsTouched(dd) {
			// Busy Hands: the day's quests count its times over while it runs.
			if err := d.bumpQuests(ctx, q, p, dd, d.questMultiplier(now)); err != nil {
				return err
			}
		}
		if err := d.countDeeds(ctx, q, p, dd, now); err != nil {
			return err
		}
		// The kingdom's shared goal reads the counters that are being written
		// here anyway (help.go). Nothing in the game reports to the goal
		// directly: a second reporting path would be a second set of numbers
		// to disagree, and this one is already inside the savepoint.
		return d.addGoalProgress(ctx, q, p, dd, now)
	})
}

// questsTouched reports an action the day's quests keep a counter for.
var questKinds = []deeds.Kind{deeds.Collects, deeds.RaidWins, deeds.Buys, deeds.Energy,
	deeds.CampaignStages, deeds.HuntsSent, deeds.AidGiven, deeds.BossHits}

func questsTouched(dd deeds.Deeds) bool {
	for _, k := range questKinds {
		if dd[k] > 0 {
			return true
		}
	}
	return false
}

// countDeeds writes one action's deeds to every scope they belong to, and
// what they earn on the Royal Charter and in the running festival. Everything
// recordDeeds does but the day's quests: the dev tools' way in too, so a count
// pushed from the panel lands where a played one would.
func (d Deps) countDeeds(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, dd deeds.Deeds, now time.Time) error {
	var more []deeds.Period
	season := d.seasonNow(now)
	if season.Number >= 1 {
		more = append(more, deeds.Period{Scope: deeds.ScopeSeason, Period: int64(season.Number)})
	}
	fest := d.festivalAt(now)
	if fest != nil {
		more = append(more, deeds.Period{Scope: deeds.ScopeEvent, Period: fest.ID})
	}
	scopes, periods, kinds, values := deeds.Rows(dd, localDay(now, p.ResetOffsetMinutes), now, more...)
	if len(scopes) == 0 {
		return nil
	}
	if err := q.BumpDeeds(ctx, sqlcdb.BumpDeedsParams{
		PlayerID: p.ID, Scopes: scopes, Periods: periods, Deeds: kinds, Vals: values,
	}); err != nil {
		return err
	}
	if p.IsBot {
		return nil
	}
	counts := make(map[string]int64, len(dd))
	for k, v := range dd {
		counts[string(k)] = v
	}
	if season.Number >= 1 {
		sc := d.Config.LiveOps.Season
		if add := liveops.PointsMilli(sc.Sources, counts); add > 0 {
			if err := q.AddSeasonPoints(ctx, sqlcdb.AddSeasonPointsParams{
				PlayerID: p.ID, Season: int32(season.Number), Add: add, Cap: sc.DailyCap * 1000,
				Day: int16(liveops.DayOf(season.Start, now)), Now: now, Might: p.Might,
			}); err != nil {
				return err
			}
		}
	}
	if fest != nil {
		if add := liveops.PointsMilli(fest.Tpl.Points, counts); add > 0 {
			if err := q.AddEventPoints(ctx, sqlcdb.AddEventPointsParams{
				PlayerID: p.ID, EventID: fest.ID, Add: add, Cap: fest.Tpl.DailyCap * 1000,
				Day: int16(liveops.DayOf(fest.StartsAt, now)), Now: now,
			}); err != nil {
				return err
			}
		}
	}
	return nil
}
