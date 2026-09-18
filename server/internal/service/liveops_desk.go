package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The live-ops desk: what the panel reads and sets of the realm's calendar.
// The panel's own package checks roles and writes the audit; the rules of the
// hour, the festival and the season live here, beside the game that plays them.

var (
	// ErrHourStarted is setting an hour that has begun (or is gone).
	ErrHourStarted = errors.New("that hour has already begun")
	// ErrHourTooFar is setting an hour more than a day ahead.
	ErrHourTooFar = errors.New("an hour can be set up to a day ahead")
	// ErrNoSuchHourly is an event the hourly table does not have.
	ErrNoSuchHourly = errors.New("the hourly table has no such event")
	// ErrFestivalPast is a festival scheduled to start in the past.
	ErrFestivalPast = errors.New("a festival starts now or later")
)

// hourlyDeskAhead is how far ahead the panel may set an hour.
const hourlyDeskAhead = 24

// HourSlot is one hour on the panel's schedule.
type HourSlot struct {
	Hour     int64  `json:"hour"`
	StartsAt string `json:"starts_at"`
	EventID  string `json:"event_id"`
	Name     string `json:"name"`
	Icon     string `json:"icon"`
	Minutes  int    `json:"minutes"`
	// roll (written down as rolled) | forced | skipped | predicted (not yet
	// written: what the roll will say unless the panel sets it).
	Source string `json:"source"`
	SetBy  string `json:"set_by,omitempty"`
	Note   string `json:"note,omitempty"`
	// The hour running now; one the panel may still set.
	Current  bool `json:"current"`
	Settable bool `json:"settable"`
	// Lords who took its gift or its free rerolls.
	Lords int `json:"lords"`
}

// HourlySchedule is the day behind and the day ahead, hour by hour.
func (d Deps) HourlySchedule(ctx context.Context) ([]HourSlot, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	h := liveops.Hour(now)
	from, to := h-24, h+hourlyDeskAhead
	rows, err := q.ListHourlyEvents(ctx, sqlcdb.ListHourlyEventsParams{FromHour: from - hourlyLookback - 1, ToHour: to})
	if err != nil {
		return nil, err
	}
	written := make(map[int64]sqlcdb.AdminHourlyEvent, len(rows))
	ids := make(map[int64]string, len(rows))
	for _, r := range rows {
		written[r.Hour] = r
		ids[r.Hour] = r.EventID
	}
	uses := map[int64]int{}
	if us, err := q.CountHourlyUses(ctx, sqlcdb.CountHourlyUsesParams{FromHour: from, ToHour: to}); err == nil {
		for _, u := range us {
			uses[u.Hour] = int(u.Lords)
		}
	}
	out := make([]HourSlot, 0, to-from+1)
	for hr := from; hr <= to; hr++ {
		slot := HourSlot{Hour: hr, StartsAt: liveops.HourStart(hr).Format("2006-01-02 15:04"),
			Current: hr == h, Settable: hr > h, Lords: uses[hr]}
		if r, ok := written[hr]; ok {
			slot.EventID, slot.Source, slot.Note = r.EventID, r.Source, r.Note
			if r.SetBy != nil {
				slot.SetBy = *r.SetBy
			}
		} else {
			slot.EventID = liveops.HourlyAt(d.ShopSecret, d.Config.LiveOps.Hourly, ids, hr)
			slot.Source = "predicted"
		}
		// Later hours roll on from this one.
		ids[hr] = slot.EventID
		if e := d.Config.LiveOps.Hourly.Event(slot.EventID); e != nil {
			slot.Name, slot.Icon, slot.Minutes = e.Name, e.Icon, e.Minutes
		}
		if slot.EventID == gameconfig.HourlyNone {
			slot.Name = "Quiet hour"
		}
		out = append(out, slot)
	}
	return out, nil
}

// SetHourlySlot forces an hour's event (eventID), skips it ("none"), or gives
// it back to the roll (""). Only an hour not yet begun, up to a day ahead.
func (d Deps) SetHourlySlot(ctx context.Context, hour int64, eventID, by, note string) error {
	h := liveops.Hour(d.Now())
	switch {
	case hour <= h:
		return ErrHourStarted
	case hour > h+hourlyDeskAhead:
		return ErrHourTooFar
	}
	q := sqlcdb.New(d.Pool)
	var err error
	switch {
	case eventID == "":
		_, err = q.ClearHourly(ctx, hour)
	case eventID == gameconfig.HourlyNone:
		_, err = q.SetHourly(ctx, sqlcdb.SetHourlyParams{Hour: hour, EventID: gameconfig.HourlyNone,
			Source: "skipped", SetBy: &by, Note: note})
	default:
		if d.Config.LiveOps.Hourly.Event(eventID) == nil {
			return fmt.Errorf("%w: %q", ErrNoSuchHourly, eventID)
		}
		_, err = q.SetHourly(ctx, sqlcdb.SetHourlyParams{Hour: hour, EventID: eventID,
			Source: "forced", SetBy: &by, Note: note})
	}
	if err != nil {
		return err
	}
	if d.Boosts != nil {
		_ = d.Boosts.Refresh(ctx)
	}
	return nil
}

// FestivalRow is one festival on the panel's calendar.
type FestivalRow struct {
	ID         int64  `json:"id"`
	TemplateID string `json:"template_id"`
	Name       string `json:"name"`
	Theme      string `json:"theme"`
	Bucket     string `json:"bucket"`
	BP         int64  `json:"bp"`
	StartsAt   string `json:"starts_at"`
	EndsAt     string `json:"ends_at"`
	// scheduled | running | closing (ended, not yet closed) | closed | revoked
	Status    string `json:"status"`
	Lords     int    `json:"lords"`
	Note      string `json:"note"`
	CreatedBy string `json:"created_by"`
	RevokedBy string `json:"revoked_by,omitempty"`
}

// FestivalTemplateRow is a template the panel can schedule.
type FestivalTemplateRow struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Theme  string `json:"theme"`
	Blurb  string `json:"blurb"`
	Days   int    `json:"days"`
	Bucket string `json:"bucket"`
	BP     int64  `json:"bp"`
}

// FestivalCalendar is the panel's festivals page.
type FestivalCalendar struct {
	Festivals []FestivalRow         `json:"festivals"`
	Templates []FestivalTemplateRow `json:"templates"`
	// How far ahead the game announces a festival.
	AnnounceHours int `json:"announce_hours"`
}

// Festivals lists the calendar, newest first, with the templates to schedule.
func (d Deps) Festivals(ctx context.Context) (*FestivalCalendar, error) {
	rows, err := sqlcdb.New(d.Pool).ListLiveEvents(ctx, 50)
	if err != nil {
		return nil, err
	}
	now := d.Now()
	out := &FestivalCalendar{Festivals: []FestivalRow{}, Templates: []FestivalTemplateRow{},
		AnnounceHours: d.Config.LiveOps.Events.AnnounceHours}
	for _, r := range rows {
		f, err := festivalOf(sqlcdb.AdminLiveEvent{ID: r.ID, StartsAt: r.StartsAt, EndsAt: r.EndsAt, Frozen: r.Frozen})
		if err != nil {
			continue
		}
		st := "scheduled"
		switch {
		case r.RevokedAt != nil:
			st = "revoked"
		case r.SettledAt != nil:
			st = "closed"
		case !now.Before(r.EndsAt):
			st = "closing"
		case !now.Before(r.StartsAt):
			st = "running"
		}
		row := FestivalRow{ID: r.ID, TemplateID: r.TemplateID, Name: f.Tpl.Name, Theme: f.Tpl.Theme,
			Bucket: f.Tpl.Effect.Bucket, BP: f.Tpl.Effect.BP,
			StartsAt: r.StartsAt.UTC().Format("2006-01-02 15:04"), EndsAt: r.EndsAt.UTC().Format("2006-01-02 15:04"),
			Status: st, Lords: int(r.Lords), Note: r.Note, CreatedBy: r.CreatedBy}
		if r.RevokedBy != nil {
			row.RevokedBy = *r.RevokedBy
		}
		out.Festivals = append(out.Festivals, row)
	}
	for _, t := range d.Config.LiveOps.Events.Templates {
		out.Templates = append(out.Templates, FestivalTemplateRow{ID: t.ID, Name: t.Name, Theme: t.Theme,
			Blurb: t.Blurb, Days: t.Days, Bucket: t.Effect.Bucket, BP: t.Effect.BP})
	}
	return out, nil
}

// ScheduleFestivalAt is the panel's schedule: a template, to start at a
// moment not in the past.
func (d Deps) ScheduleFestivalAt(ctx context.Context, templateID string, startsAt time.Time, by, note string) (*sqlcdb.AdminLiveEvent, error) {
	if startsAt.Before(d.Now().Add(-time.Minute)) {
		return nil, ErrFestivalPast
	}
	return d.ScheduleFestival(ctx, templateID, startsAt, by, note)
}

// FestivalStanding is one place on a festival's board, for the panel.
type FestivalStanding struct {
	Place    int    `json:"place"`
	PlayerID string `json:"player_id"`
	Name     string `json:"name"`
	Level    int64  `json:"level"`
	Points   int64  `json:"points"`
}

// FestivalBoard is a festival's board as it stands (or stood).
func (d Deps) FestivalBoard(ctx context.Context, id int64) ([]FestivalStanding, error) {
	rows, err := sqlcdb.New(d.Pool).EventBoard(ctx, sqlcdb.EventBoardParams{EventID: id, Lim: 100})
	if err != nil {
		return nil, err
	}
	out := make([]FestivalStanding, 0, len(rows))
	for i, r := range rows {
		out = append(out, FestivalStanding{Place: i + 1, PlayerID: r.PlayerID.String(), Name: r.DisplayName,
			Level: int64(r.Level), Points: r.PointsMilli / 1000})
	}
	return out, nil
}

// SeasonDesk is the panel's season page.
type SeasonDesk struct {
	Number   int    `json:"number"`
	StartsAt string `json:"starts_at"`
	EndsAt   string `json:"ends_at"`
	Day      int    `json:"day"`
	Days     int    `json:"days"`
	// Lords with a Charter this season, those whose royal lane is open, and
	// of those how many bought it with money.
	Lords       int   `json:"lords"`
	Royal       int   `json:"royal"`
	RoyalBought int   `json:"royal_bought"`
	Points      int64 `json:"points"`
	TopPoints   int64 `json:"top_points"`
	// Lords per band of ten tiers (0-9, 10-19, ... 50).
	Bands []SeasonBand       `json:"bands"`
	Top   []FestivalStanding `json:"top"`
	// The closes the jobs have written: boards, nobility, leftover Charters.
	Closes []PeriodCloseRow `json:"closes"`
}

// SeasonBand is how many lords reached a band of tiers.
type SeasonBand struct {
	From  int `json:"from"`
	To    int `json:"to"`
	Lords int `json:"lords"`
}

// PeriodCloseRow is one close a job finished.
type PeriodCloseRow struct {
	What     string `json:"what"`
	Period   int64  `json:"period"`
	ClosedAt string `json:"closed_at"`
	Lords    int    `json:"lords"`
}

// SeasonSummary is the running season for the panel.
func (d Deps) SeasonSummary(ctx context.Context) (*SeasonDesk, error) {
	q := sqlcdb.New(d.Pool)
	now := d.Now()
	sc := d.Config.LiveOps.Season
	s := d.seasonNow(now)
	out := &SeasonDesk{Number: s.Number, StartsAt: s.Start.Format("2006-01-02"), EndsAt: s.End.Format("2006-01-02"),
		Day: liveops.DayOf(s.Start, now), Days: sc.Days, Bands: []SeasonBand{}, Top: []FestivalStanding{},
		Closes: []PeriodCloseRow{}}
	if s.Number >= 1 {
		sum, err := q.SeasonSummary(ctx, int32(s.Number))
		if err != nil {
			return nil, err
		}
		out.Lords, out.Royal, out.RoyalBought = int(sum.Lords), int(sum.Royal), int(sum.RoyalBought)
		out.Points, out.TopPoints = sum.PointsMilli/1000, sum.TopMilli/1000
		bands, err := q.SeasonTierBands(ctx, sqlcdb.SeasonTierBandsParams{Season: int32(s.Number),
			Tiers: int32(sc.Tiers), PerTier: sc.PointsPerTier})
		if err != nil {
			return nil, err
		}
		for _, b := range bands {
			from := int(b.Band) * 10
			out.Bands = append(out.Bands, SeasonBand{From: from, To: min(from+9, sc.Tiers), Lords: int(b.Lords)})
		}
		top, err := q.SeasonBoard(ctx, sqlcdb.SeasonBoardParams{Season: int32(s.Number), Lim: 10})
		if err != nil {
			return nil, err
		}
		for i, r := range top {
			out.Top = append(out.Top, FestivalStanding{Place: i + 1, PlayerID: r.PlayerID.String(),
				Name: r.DisplayName, Level: int64(r.Level), Points: r.PointsMilli / 1000})
		}
	}
	closes, err := q.ListPeriodCloses(ctx, 20)
	if err != nil {
		return nil, err
	}
	for _, c := range closes {
		out.Closes = append(out.Closes, PeriodCloseRow{What: c.What, Period: c.Period,
			ClosedAt: c.ClosedAt.UTC().Format("2006-01-02 15:04"), Lords: int(c.Lords)})
	}
	return out, nil
}
