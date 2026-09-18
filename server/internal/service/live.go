package service

import (
	"context"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// LiveView is what is running for everyone, and what it is worth to this lord:
// the one place the game reads a server-wide modifier from. The later waves
// fill it further -- the hourly event, the calendar's events, the season, the
// throne's edict -- each as another list here, so the client has one block to
// read and one place to draw a banner from.
type LiveView struct {
	// Operator events in force now (the panel's Events page).
	Boosts []LiveBoost `json:"boosts"`
	// Events scheduled to start within a day, soonest first.
	Upcoming []LiveBoost `json:"upcoming"`
	// The hour's event (liveops.go): what is on, until when, and what the next
	// hour brings.
	Hourly LiveHourly `json:"hourly"`
	// The festival running, or the next one announced. Nil when neither is.
	Festival *LiveFestival `json:"festival"`
	// The season and this lord's Royal Charter in it (season.go).
	Season LiveSeason `json:"season"`
	// The reign, and its edict if one is in force (throne.go). Nil when nobody
	// sits the throne. Realm news: it is here so the Kingdom tab's banner reads
	// without a request of its own, and so a lord with no kingdom still sees it.
	Throne *LiveThrone `json:"throne"`
}

// LiveHourly is the hour's event as this lord stands to it.
type LiveHourly struct {
	// Empty for a quiet hour; then only NextIn and Next say anything.
	ID    string `json:"id"`
	Name  string `json:"name,omitempty"`
	Blurb string `json:"blurb,omitempty"`
	// Its art key (hourly/<id>).
	Icon string `json:"icon,omitempty"`
	// boost | refill_discount | free_reroll | quest_multiplier | gift
	Kind string `json:"kind,omitempty"`
	// A boost's bucket and figure, and what it is worth to this lord (the
	// timed lane after its cap, with every other timed bonus they hold). A
	// refill discount's figure is BP too.
	Bucket      string `json:"bucket,omitempty"`
	BP          int64  `json:"bp,omitempty"`
	EffectiveBP int64  `json:"effective_bp,omitempty"`
	// Busy Hands' multiplier.
	X int64 `json:"x,omitempty"`
	// What this lord has left of it: the courier's gift (1 or 0), the free
	// rerolls not yet taken.
	Left int `json:"left"`
	// What the courier brings.
	Lines []rewards.Line `json:"lines,omitempty"`
	// Running now (an event lasts its minutes from the top of the hour; after
	// them the hour is over, though the next has not begun).
	Active bool `json:"active"`
	// Seconds until it ends (0 once over) and until the next hour's event.
	EndsIn int64 `json:"ends_in"`
	NextIn int64 `json:"next_in"`
	// The next hour's event, nil when it is quiet.
	Next *LiveHourlyNext `json:"next"`
}

// LiveHourlyNext is the next hour's event, announced.
type LiveHourlyNext struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Icon  string `json:"icon"`
}

// LiveFestival is a festival as the banner and the Court card show it.
type LiveFestival struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Theme string `json:"theme"`
	Blurb string `json:"blurb"`
	// The realm-wide bonus: collect_income_bp, xp_bp, reputation_bp or
	// shop_discount_bp, and what it is worth to this lord now.
	Bucket      string `json:"bucket"`
	BP          int64  `json:"bp"`
	EffectiveBP int64  `json:"effective_bp"`
	Running     bool   `json:"running"`
	// Seconds until it starts (announced only) and until it ends.
	StartsIn int64 `json:"starts_in"`
	EndsIn   int64 `json:"ends_in"`
	// This lord's points in it (whole points).
	Points int64 `json:"points"`
}

// LiveSeason is the season as the rail and the Court card show it.
type LiveSeason struct {
	Number int   `json:"number"`
	EndsIn int64 `json:"ends_in"`
	Tier   int   `json:"tier"`
	Tiers  int   `json:"tiers"`
	Royal  bool  `json:"royal"`
}

// LiveBoost is one bucket's server event.
type LiveBoost struct {
	// collect_income, xp or luck (service.BoostableBuckets).
	Bucket string `json:"bucket"`
	// What the event gives, in basis points.
	BP int64 `json:"bp"`
	// What it is worth to this lord: the timed lane of the bucket after its
	// own cap, with every other timed bonus they hold -- the number a banner
	// should say ("+50% for you"). For luck, the event's own figure.
	EffectiveBP int64 `json:"effective_bp"`
	// Seconds until it starts (upcoming only) and until it ends.
	StartsIn int64 `json:"starts_in,omitempty"`
	EndsIn   int64 `json:"ends_in"`
}

// liveView reads the server's events for one lord at a moment. What it reads
// for the lord alone (their use of the hour, their festival and season rows)
// is a primary-key lookup each; one that fails leaves its part at zero.
func (d Deps) liveView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) LiveView {
	ev := d.Boosts.Events()
	out := LiveView{Boosts: []LiveBoost{}, Upcoming: []LiveBoost{}}
	out.Hourly = d.liveHourly(ctx, q, p, eff, now)
	out.Festival = d.liveFestival(ctx, q, p, eff, now)
	out.Season = d.liveSeason(ctx, q, p, now)
	out.Throne = d.liveThrone(ctx, q, p, eff, now)
	for _, e := range ev.Live {
		out.Boosts = append(out.Boosts, LiveBoost{
			Bucket: e.Bucket, BP: e.BP, EffectiveBP: effectiveEventBP(eff, e.Bucket, e.BP),
			EndsIn: secondsUntil(e.EndsAt, now),
		})
	}
	for _, e := range ev.Upcoming {
		out.Upcoming = append(out.Upcoming, LiveBoost{
			Bucket: e.Bucket, BP: e.BP, EffectiveBP: e.BP,
			StartsIn: secondsUntil(e.StartsAt, now), EndsIn: secondsUntil(e.EndsAt, now),
		})
	}
	return out
}

// effectiveEventBP is what a live event is worth to a lord right now.
func effectiveEventBP(eff estates.Effects, bucket string, bp int64) int64 {
	switch bucket {
	case gameconfig.BucketCollectIncome:
		return economy.TempBP(eff.Bonuses, economy.BucketCollectIncome)
	case gameconfig.BucketXP:
		return economy.TempBP(eff.Bonuses, economy.BucketXPGain)
	}
	return bp
}

// liveBonusWorth is what a running festival's bonus is worth to a lord: for
// gold and experience the timed lane after its cap; for the market's discount
// the whole of what the market takes off for them, after its ceiling (the
// festival's tenth and their own discount together); renown as it stands.
func liveBonusWorth(cfg *gameconfig.Bundle, eff estates.Effects, bucket string, bp int64) int64 {
	if bucket == gameconfig.BucketShopDiscount {
		return min(eff.ShopDiscount, items.MaxDiscountBP(cfg))
	}
	return effectiveEventBP(eff, bucket, bp)
}

// liveHourly is the hour's event for one lord.
func (d Deps) liveHourly(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) LiveHourly {
	h := d.hourAt(now)
	out := LiveHourly{NextIn: secondsUntil(liveops.HourStart(h.Hour+1), now)}
	if next := d.hourOf(h.Hour+1, now); next.Event != nil {
		out.Next = &LiveHourlyNext{ID: next.Event.ID, Name: next.Event.Name, Blurb: next.Event.Blurb, Icon: next.Event.Icon}
	}
	if h.Event == nil {
		return out
	}
	e := h.Event
	out.ID, out.Name, out.Blurb, out.Icon, out.Kind = e.ID, e.Name, e.Blurb, e.Icon, e.Effect.Kind
	out.Active = h.Active
	out.EndsIn = secondsUntil(h.EndsAt, now)
	switch e.Effect.Kind {
	case gameconfig.HourlyBoost:
		out.Bucket, out.BP = e.Effect.Bucket, e.Effect.BP
		out.EffectiveBP = e.Effect.BP
		if h.Active {
			out.EffectiveBP = effectiveEventBP(eff, e.Effect.Bucket, e.Effect.BP)
		}
	case gameconfig.HourlyRefillDiscount:
		out.BP = e.Effect.BP
	case gameconfig.HourlyQuestMultiplier:
		out.X = e.Effect.X
	case gameconfig.HourlyGift:
		out.Lines = d.linesOf(p, eff, e.Effect.Grant)
	}
	out.Left = d.hourlyUsesLeft(ctx, q, p.ID, h)
	return out
}

// liveFestival is the festival running (or the next announced) for one lord.
func (d Deps) liveFestival(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) *LiveFestival {
	f := d.festivalAt(now)
	running := f != nil
	if f == nil {
		if f = d.nextFestival(now); f == nil {
			return nil
		}
	}
	out := &LiveFestival{
		ID: f.ID, Name: f.Tpl.Name, Theme: f.Tpl.Theme, Blurb: f.Tpl.Blurb,
		Bucket: f.Tpl.Effect.Bucket, BP: f.Tpl.Effect.BP, EffectiveBP: f.Tpl.Effect.BP,
		Running: running, StartsIn: secondsUntil(f.StartsAt, now), EndsIn: secondsUntil(f.EndsAt, now),
	}
	if running {
		out.EffectiveBP = liveBonusWorth(d.Config, eff, f.Tpl.Effect.Bucket, f.Tpl.Effect.BP)
		if row, err := q.GetPlayerEvent(ctx, sqlcdb.GetPlayerEventParams{PlayerID: p.ID, EventID: f.ID}); err == nil {
			out.Points = row.PointsMilli / 1000
		}
	}
	return out
}

func secondsUntil(t, now time.Time) int64 {
	if !t.After(now) {
		return 0
	}
	return int64(t.Sub(now) / time.Second)
}
