package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The realm's calendar (liveops.json): the hourly event, rolled at the top of
// every hour, and the festivals the panel schedules. Both are read off the
// boost poll (Boosts), never per request: loadEffects runs before every
// action, and what is on this hour changes once an hour.
//
// With no poll (a Deps built by hand: tests, tools) nothing is on -- the same
// rule the operator's boosts follow -- so no test's numbers move with the hour
// it happens to run at.

const (
	// The written-down hours the poll holds: the roll's whole no-repeat chain
	// behind the hour, and the next ones, which the panel may have set.
	hourlyLookback  = liveops.Lookback
	hourlyLookahead = 2
	// How far ahead the poll reads the festival calendar. What the game
	// announces is the balance's announce_hours, within this.
	festivalWindow = 7 * 24 * time.Hour
	// How long a lord's use of an hour is kept.
	hourlyUseKeep = 48
)

var (
	// ErrHourlyNone is a claim on an hour with no gift running.
	ErrHourlyNone = errors.New("the courier is not in the realm this hour")
	// ErrHourlyClaimed is the hour's gift, already taken.
	ErrHourlyClaimed = errors.New("you have already taken this hour's gift")
)

// Festival is a scheduled festival as it was frozen.
type Festival struct {
	ID       int64
	StartsAt time.Time
	EndsAt   time.Time
	Tpl      gameconfig.EventTemplate
}

func festivalOf(r sqlcdb.AdminLiveEvent) (Festival, error) {
	var t gameconfig.EventTemplate
	if err := json.Unmarshal(r.Frozen, &t); err != nil {
		return Festival{}, fmt.Errorf("festival %d: %w", r.ID, err)
	}
	return Festival{ID: r.ID, StartsAt: r.StartsAt, EndsAt: r.EndsAt, Tpl: t}, nil
}

// HourNow is an hour's event as it stands at an instant.
type HourNow struct {
	Hour int64
	// Nil for a quiet hour.
	Event *gameconfig.HourlyEvent
	// Within its minutes from the top of the hour.
	Active bool
	EndsAt time.Time
}

// hourOf is hour h's event, judged at now.
func (d Deps) hourOf(h int64, now time.Time) HourNow {
	out := HourNow{Hour: h}
	if d.Boosts == nil {
		return out
	}
	id := liveops.HourlyAt(d.ShopSecret, d.Config.LiveOps.Hourly, d.Boosts.HourlyRows(), h)
	ev := d.Config.LiveOps.Hourly.Event(id)
	if ev == nil || id == gameconfig.HourlyNone {
		return out
	}
	start := liveops.HourStart(h)
	out.Event = ev
	out.EndsAt = start.Add(time.Duration(ev.Minutes) * time.Minute)
	out.Active = !now.Before(start) && now.Before(out.EndsAt)
	return out
}

// hourAt is the hour now falls in.
func (d Deps) hourAt(now time.Time) HourNow { return d.hourOf(liveops.Hour(now), now) }

// runningHourly is the hour's event when it is running and does kind; nil
// otherwise.
func (d Deps) runningHourly(now time.Time, kind string) *HourNow {
	h := d.hourAt(now)
	if h.Event == nil || !h.Active || h.Event.Effect.Kind != kind {
		return nil
	}
	return &h
}

// festivalAt is the festival running at an instant, or nil.
func (d Deps) festivalAt(now time.Time) *Festival {
	for _, f := range d.Boosts.Festivals() {
		if !now.Before(f.StartsAt) && now.Before(f.EndsAt) {
			f := f
			return &f
		}
	}
	return nil
}

// nextFestival is the next festival announced: scheduled to start within the
// balance's announce_hours. Nil when none is.
func (d Deps) nextFestival(now time.Time) *Festival {
	until := now.Add(time.Duration(d.Config.LiveOps.Events.AnnounceHours) * time.Hour)
	for _, f := range d.Boosts.Festivals() {
		if f.StartsAt.After(now) && !f.StartsAt.After(until) {
			f := f
			return &f
		}
	}
	return nil
}

// linesOf writes out what a bundle would pay this lord, as a reward screen
// says it.
func (d Deps) linesOf(p sqlcdb.AppPlayer, eff estates.Effects, b gameconfig.RewardBundle) []rewards.Line {
	return rewards.Lines(d.Config, b, rewards.Resolve(d.Config, b, int(p.Level), eff.Bonuses))
}

// questMultiplier is how many times over the day's quests count right now:
// Busy Hands' x2 while it runs, else 1.
func (d Deps) questMultiplier(now time.Time) int64 {
	if h := d.runningHourly(now, gameconfig.HourlyQuestMultiplier); h != nil && h.Event.Effect.X > 1 {
		return h.Event.Effect.X
	}
	return 1
}

// hourlyUsesLeft is what a lord has left of the hour's gift or free rerolls.
func (d Deps) hourlyUsesLeft(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, h HourNow) int {
	if h.Event == nil || !h.Active {
		return 0
	}
	allowed := 0
	switch h.Event.Effect.Kind {
	case gameconfig.HourlyGift:
		allowed = 1
	case gameconfig.HourlyFreeReroll:
		allowed = h.Event.Effect.Count
	default:
		return 0
	}
	used, err := q.GetHourlyUse(ctx, sqlcdb.GetHourlyUseParams{PlayerID: playerID, Hour: h.Hour})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return 0
	}
	return max(0, allowed-int(used))
}

// HourlyClaim is what the Royal Courier brought.
type HourlyClaim struct {
	Granted  Granted   `json:"granted"`
	Snapshot *Snapshot `json:"snapshot"`
}

// ClaimHourly takes the running hour's gift, once.
//
// Asynchronous, as a letter is: it never moves action_seq, so the client
// adopts its snapshot with adopt_async.
func (d Deps) ClaimHourly(ctx context.Context, playerID uuid.UUID) (*HourlyClaim, error) {
	var g Granted
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.State == "banned" {
			return ErrPlayerBanned
		}
		g, err = d.claimHourlyGift(ctx, q, &p, d.Now())
		return err
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return &HourlyClaim{Granted: g, Snapshot: snap}, nil
}

// claimHourlyGift pays the running hour's gift to a locked lord: the claim
// endpoint's and the Steward's one way in.
func (d Deps) claimHourlyGift(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, now time.Time) (Granted, error) {
	h := d.runningHourly(now, gameconfig.HourlyGift)
	if h == nil {
		return Granted{}, ErrHourlyNone
	}
	if _, err := q.UseHourly(ctx, sqlcdb.UseHourlyParams{PlayerID: p.ID, Hour: h.Hour, Max: 1}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Granted{}, ErrHourlyClaimed
		}
		return Granted{}, fmt.Errorf("use the hour: %w", err)
	}
	return d.grantBundle(ctx, q, p, h.Event.Effect.Grant, GrantSource{
		Diamonds: ledger.Hourly, Gold: "hourly", Ref: fmt.Sprintf("hourly:%d", h.Hour), ItemFrom: "event",
	})
}

// freezeHours writes down the hour running and the next, as the roll has
// them, so a balance published mid-hour changes nothing already running or
// announced. A row already there -- the panel's, or another server's -- stands.
func freezeHours(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	h := liveops.Hour(now)
	rows, err := q.ListHourlyEvents(ctx, sqlcdb.ListHourlyEventsParams{
		FromHour: h - hourlyLookback - 1, ToHour: h + 1,
	})
	if err != nil {
		return fmt.Errorf("hourly rows: %w", err)
	}
	written := make(map[int64]string, len(rows))
	for _, r := range rows {
		written[r.Hour] = r.EventID
	}
	for _, hr := range []int64{h, h + 1} {
		if _, ok := written[hr]; ok {
			continue
		}
		id := liveops.HourlyAt(d.ShopSecret, d.Config.LiveOps.Hourly, written, hr)
		if err := q.FreezeHourly(ctx, sqlcdb.FreezeHourlyParams{Hour: hr, EventID: id}); err != nil {
			return fmt.Errorf("freeze hour %d: %w", hr, err)
		}
		written[hr] = id
	}
	if _, err := q.PurgeHourlyUse(ctx, h-hourlyUseKeep); err != nil {
		return fmt.Errorf("purge hourly use: %w", err)
	}
	if d.Boosts != nil {
		// Serve what was just written without waiting for the poll.
		return d.Boosts.Refresh(ctx)
	}
	return nil
}
