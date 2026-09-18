package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The calendar's festivals (liveops.events): three days each, scheduled from
// the panel off a template and frozen as it stood. While one runs, its bonus is
// on for the whole realm (loadEffects), what its lords do earns its points
// under a day's cap (recordDeeds) and counts toward its five tasks, and its
// points open milestones. When it ends, closeFestival pays its board's places
// by letter, with whatever each lord left unclaimed.

var (
	// ErrNoFestival is a claim with no festival running.
	ErrNoFestival = errors.New("no festival is running")
	// ErrFestivalEmpty is a claim with nothing done and unclaimed.
	ErrFestivalEmpty = errors.New("there is nothing in the festival to claim")
	// ErrFestivalClash is a festival scheduled over another.
	ErrFestivalClash = errors.New("another festival runs in that window")
)

// Festival reward kinds a claim names.
const (
	FestivalTask      = "task"
	FestivalMilestone = "milestone"
)

// FestivalTaskView is one of a festival's five tasks, as this lord stands.
type FestivalTaskView struct {
	Index    int            `json:"index"`
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Short    string         `json:"short"`
	Icon     string         `json:"icon"`
	Target   int64          `json:"target"`
	Progress int64          `json:"progress"`
	Done     bool           `json:"done"`
	Claimed  bool           `json:"claimed"`
	Lines    []rewards.Line `json:"lines"`
}

// FestivalMilestoneView is one of a festival's point milestones.
type FestivalMilestoneView struct {
	Index   int   `json:"index"`
	At      int64 `json:"at"`
	Reached bool  `json:"reached"`
	Claimed bool  `json:"claimed"`
	// The last milestone: the festival's own frame.
	Crown bool           `json:"crown"`
	Lines []rewards.Line `json:"lines"`
}

// PlaceRewardView is what a run of places pays.
type PlaceRewardView struct {
	From  int            `json:"from"`
	To    int            `json:"to"`
	Lines []rewards.Line `json:"lines"`
}

// BoardRow is one place on a festival's or a season's board.
type BoardRow struct {
	Place  int    `json:"place"`
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Level  int64  `json:"level"`
	Points int64  `json:"points"`
	Me     bool   `json:"me"`
	Look
}

// FestivalView is a festival as its page shows it.
type FestivalView struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Theme string `json:"theme"`
	Blurb string `json:"blurb"`
	// The realm's bonus, and what it is worth to this lord now.
	Bucket      string `json:"bucket"`
	BP          int64  `json:"bp"`
	EffectiveBP int64  `json:"effective_bp"`
	Running     bool   `json:"running"`
	StartsIn    int64  `json:"starts_in"`
	EndsIn      int64  `json:"ends_in"`
	Day         int    `json:"day"`
	Days        int    `json:"days"`
	// Whole points; today's against the day's cap; the lord's place (0 with
	// no points).
	Points     int64                   `json:"points"`
	DayPoints  int64                   `json:"day_points"`
	DayCap     int64                   `json:"day_cap"`
	Place      int                     `json:"place"`
	Lords      int                     `json:"lords"`
	Claimable  int                     `json:"claimable"`
	Sources    []PointsLine            `json:"sources"`
	Tasks      []FestivalTaskView      `json:"tasks"`
	Milestones []FestivalMilestoneView `json:"milestones"`
	Ranks      []PlaceRewardView       `json:"ranks"`
	Board      []BoardRow              `json:"board"`
}

// FestivalCard is a festival announced or past, as a card on the page.
type FestivalCard struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Theme    string `json:"theme"`
	Blurb    string `json:"blurb"`
	Bucket   string `json:"bucket"`
	BP       int64  `json:"bp"`
	StartsIn int64  `json:"starts_in"`
	EndsIn   int64  `json:"ends_in"`
	// Past festivals: this lord's points in it (whole), and seconds since it
	// closed.
	Points   int64 `json:"points"`
	EndedAgo int64 `json:"ended_ago"`
}

// HourlyInfo is one row of the hourly table as the page publishes it.
type HourlyInfo struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Blurb   string `json:"blurb"`
	Icon    string `json:"icon"`
	Minutes int    `json:"minutes"`
	// Its chance an hour, in basis points (the published odds).
	BP int64 `json:"bp"`
}

// EventsView is the Events page: the festival running (or the next), those
// announced after it, the last few past, and the hourly event's table.
type EventsView struct {
	Current  *FestivalView  `json:"current"`
	Upcoming []FestivalCard `json:"upcoming"`
	Past     []FestivalCard `json:"past"`
	Hourly   LiveHourly     `json:"hourly"`
	// The hourly table's odds, "none" included (its chance of a quiet hour).
	HourlyTable []HourlyInfo `json:"hourly_table"`
}

// FestivalClaim is what a claim paid.
type FestivalClaim struct {
	Lines    []rewards.Line `json:"lines"`
	Events   *EventsView    `json:"events"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// festivalOpen is what a lord's festival row has done and not claimed.
func festivalOpen(f *Festival, row sqlcdb.AppPlayerEvent, progress map[string]int64) (tasks, milestones []int) {
	for i, t := range f.Tpl.Tasks {
		if progress[t.Deed] >= t.Target && row.Tasks&(1<<uint(i)) == 0 {
			tasks = append(tasks, i)
		}
	}
	at := make([]int64, len(f.Tpl.Milestones))
	for i, m := range f.Tpl.Milestones {
		at[i] = m.At
	}
	milestones = liveops.Open(liveops.Reached(at, row.PointsMilli/1000), uint64(row.Milestones))
	return tasks, milestones
}

// festivalProgress is a lord's deeds in a festival.
func festivalProgress(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, festivalID int64) (map[string]int64, error) {
	rows, err := q.ListDeeds(ctx, sqlcdb.ListDeedsParams{PlayerID: playerID, Scope: deeds.ScopeEvent, Period: festivalID})
	if err != nil {
		return nil, fmt.Errorf("festival deeds: %w", err)
	}
	out := make(map[string]int64, len(rows))
	for _, r := range rows {
		out[r.Deed] = r.Value
	}
	return out, nil
}

// festivalClaimable is what waits in the running festival: the badge.
func (d Deps) festivalClaimable(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, now time.Time) int {
	f := d.festivalAt(now)
	if f == nil {
		return 0
	}
	row, err := q.GetPlayerEvent(ctx, sqlcdb.GetPlayerEventParams{PlayerID: p.ID, EventID: f.ID})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return 0
		}
		row = sqlcdb.AppPlayerEvent{PlayerID: p.ID, EventID: f.ID}
	}
	progress, err := festivalProgress(ctx, q, p.ID, f.ID)
	if err != nil {
		return 0
	}
	tasks, ms := festivalOpen(f, row, progress)
	return len(tasks) + len(ms)
}

// GetEvents is the Events page.
func (d Deps) GetEvents(ctx context.Context, playerID uuid.UUID) (*EventsView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	now := d.Now()
	out := &EventsView{Upcoming: []FestivalCard{}, Past: []FestivalCard{}, HourlyTable: []HourlyInfo{}}
	out.Hourly = d.liveHourly(ctx, q, p, eff, now)
	for _, e := range d.Config.LiveOps.Hourly.Table {
		info := HourlyInfo{ID: e.ID, Name: e.Name, Blurb: e.Blurb, Icon: e.Icon, Minutes: e.Minutes, BP: e.BP}
		if e.ID == gameconfig.HourlyNone {
			info.Name, info.Blurb = "A quiet hour", "Nothing is on this hour."
		}
		out.HourlyTable = append(out.HourlyTable, info)
	}

	cur := d.festivalAt(now)
	if cur == nil {
		cur = d.nextFestival(now)
	}
	if cur != nil {
		if out.Current, err = d.festivalView(ctx, q, p, eff, cur, now); err != nil {
			return nil, err
		}
	}
	until := now.Add(time.Duration(d.Config.LiveOps.Events.AnnounceHours) * time.Hour)
	for _, f := range d.Boosts.Festivals() {
		if cur != nil && f.ID == cur.ID {
			continue
		}
		if f.StartsAt.After(now) && !f.StartsAt.After(until) {
			out.Upcoming = append(out.Upcoming, FestivalCard{
				ID: f.ID, Name: f.Tpl.Name, Theme: f.Tpl.Theme, Blurb: f.Tpl.Blurb,
				Bucket: f.Tpl.Effect.Bucket, BP: f.Tpl.Effect.BP,
				StartsIn: secondsUntil(f.StartsAt, now), EndsIn: secondsUntil(f.EndsAt, now),
			})
		}
	}
	past, err := q.RecentEventsFor(ctx, sqlcdb.RecentEventsForParams{
		PlayerID: p.ID, Now: now, Since: now.Add(-30 * 24 * time.Hour),
	})
	if err != nil {
		return nil, fmt.Errorf("past festivals: %w", err)
	}
	for _, r := range past {
		f, err := festivalOf(sqlcdb.AdminLiveEvent{ID: r.ID, StartsAt: r.StartsAt, EndsAt: r.EndsAt, Frozen: r.Frozen})
		if err != nil {
			continue
		}
		out.Past = append(out.Past, FestivalCard{
			ID: f.ID, Name: f.Tpl.Name, Theme: f.Tpl.Theme, Blurb: f.Tpl.Blurb,
			Bucket: f.Tpl.Effect.Bucket, BP: f.Tpl.Effect.BP,
			Points: r.MyPointsMilli / 1000, EndedAgo: int64(now.Sub(r.EndsAt) / time.Second),
		})
	}
	return out, nil
}

// festivalView is one festival for one lord.
func (d Deps) festivalView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer,
	eff estates.Effects, f *Festival, now time.Time) (*FestivalView, error) {
	running := !now.Before(f.StartsAt) && now.Before(f.EndsAt)
	v := &FestivalView{
		ID: f.ID, Name: f.Tpl.Name, Theme: f.Tpl.Theme, Blurb: f.Tpl.Blurb,
		Bucket: f.Tpl.Effect.Bucket, BP: f.Tpl.Effect.BP, EffectiveBP: f.Tpl.Effect.BP,
		Running: running, StartsIn: secondsUntil(f.StartsAt, now), EndsIn: secondsUntil(f.EndsAt, now),
		Days: f.Tpl.Days, DayCap: f.Tpl.DailyCap, Sources: pointsLines(f.Tpl.Points),
		Tasks: []FestivalTaskView{}, Milestones: []FestivalMilestoneView{}, Ranks: []PlaceRewardView{},
		Board: []BoardRow{},
	}
	if running {
		v.Day = liveops.DayOf(f.StartsAt, now)
		v.EffectiveBP = liveBonusWorth(d.Config, eff, f.Tpl.Effect.Bucket, f.Tpl.Effect.BP)
	}
	row, err := q.GetPlayerEvent(ctx, sqlcdb.GetPlayerEventParams{PlayerID: p.ID, EventID: f.ID})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("festival row: %w", err)
		}
		row = sqlcdb.AppPlayerEvent{PlayerID: p.ID, EventID: f.ID}
	}
	progress, err := festivalProgress(ctx, q, p.ID, f.ID)
	if err != nil {
		return nil, err
	}
	v.Points = row.PointsMilli / 1000
	if running && int(row.Day) == v.Day {
		v.DayPoints = row.DayMilli / 1000
	}
	for i, t := range f.Tpl.Tasks {
		n := progress[t.Deed]
		v.Tasks = append(v.Tasks, FestivalTaskView{
			Index: i, ID: t.ID, Name: t.Name, Short: t.Short, Icon: t.Icon, Target: t.Target,
			Progress: min(n, t.Target), Done: n >= t.Target, Claimed: row.Tasks&(1<<uint(i)) != 0,
			Lines: d.linesOf(p, eff, t.Grant),
		})
	}
	for i, m := range f.Tpl.Milestones {
		v.Milestones = append(v.Milestones, FestivalMilestoneView{
			Index: i, At: m.At, Reached: v.Points >= m.At, Claimed: row.Milestones&(1<<uint(i)) != 0,
			Crown: i == len(f.Tpl.Milestones)-1, Lines: d.linesOf(p, eff, m.Grant),
		})
	}
	from := 1
	for _, r := range f.Tpl.Ranks {
		v.Ranks = append(v.Ranks, PlaceRewardView{From: from, To: r.Top, Lines: d.linesOf(p, eff, r.Grant)})
		from = r.Top + 1
	}
	if running {
		tasks, ms := festivalOpen(f, row, progress)
		v.Claimable = len(tasks) + len(ms)
	}

	top := d.Config.LiveOps.Events.TopShown
	board, err := q.EventBoard(ctx, sqlcdb.EventBoardParams{EventID: f.ID, Lim: int32(top)})
	if err != nil {
		return nil, fmt.Errorf("festival board: %w", err)
	}
	for i, r := range board {
		v.Board = append(v.Board, BoardRow{
			Place: i + 1, Name: r.DisplayName, Avatar: r.Avatar, Level: int64(r.Level),
			Points: r.PointsMilli / 1000, Me: r.PlayerID == p.ID,
			Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		})
	}
	if row.PointsMilli > 0 {
		place, err := q.EventPlace(ctx, sqlcdb.EventPlaceParams{
			EventID: f.ID, PointsMilli: row.PointsMilli, PointsAt: row.PointsAt,
		})
		if err == nil {
			v.Place = int(place)
		}
	}
	if n, err := q.CountEventLords(ctx, f.ID); err == nil {
		v.Lords = int(n)
	}
	return v, nil
}

// ClaimFestival claims one task's or milestone's reward (kind and index
// given), or everything done and unclaimed (neither given), in the running
// festival.
func (d Deps) ClaimFestival(ctx context.Context, playerID uuid.UUID, kind string, index *int) (*FestivalClaim, error) {
	res := FestivalClaim{Lines: []rewards.Line{}}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		now := d.Now()
		f := d.festivalAt(now)
		if f == nil {
			return ErrNoFestival
		}
		row, err := q.EnsurePlayerEvent(ctx, sqlcdb.EnsurePlayerEventParams{PlayerID: p.ID, EventID: f.ID})
		if err != nil {
			return fmt.Errorf("festival row: %w", err)
		}
		progress, err := festivalProgress(ctx, q, p.ID, f.ID)
		if err != nil {
			return err
		}
		tasks, ms := festivalOpen(f, row, progress)
		if index != nil {
			i := *index
			switch kind {
			case FestivalTask:
				if i < 0 || i >= len(f.Tpl.Tasks) {
					return ErrNotFound
				}
				if row.Tasks&(1<<uint(i)) != 0 {
					return ErrAlreadyClaimed
				}
				if progress[f.Tpl.Tasks[i].Deed] < f.Tpl.Tasks[i].Target {
					return ErrFestivalEmpty
				}
				tasks, ms = []int{i}, nil
			case FestivalMilestone:
				if i < 0 || i >= len(f.Tpl.Milestones) {
					return ErrNotFound
				}
				if row.Milestones&(1<<uint(i)) != 0 {
					return ErrAlreadyClaimed
				}
				if row.PointsMilli/1000 < f.Tpl.Milestones[i].At {
					return ErrFestivalEmpty
				}
				tasks, ms = nil, []int{i}
			default:
				return ErrNotFound
			}
		}
		if len(tasks)+len(ms) == 0 {
			return ErrFestivalEmpty
		}
		if _, err := q.ClaimEventRewards(ctx, sqlcdb.ClaimEventRewardsParams{
			PlayerID: p.ID, EventID: f.ID,
			Tasks: int32(liveops.Mask(tasks)), Milestones: int32(liveops.Mask(ms)),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim the festival: %w", err)
		}
		for _, i := range tasks {
			g, err := d.grantBundle(ctx, q, &p, f.Tpl.Tasks[i].Grant, festivalSource(f.ID, "task", i))
			if err != nil {
				return err
			}
			res.Lines = append(res.Lines, g.Lines...)
		}
		for _, i := range ms {
			g, err := d.grantBundle(ctx, q, &p, f.Tpl.Milestones[i].Grant, festivalSource(f.ID, "milestone", i))
			if err != nil {
				return err
			}
			res.Lines = append(res.Lines, g.Lines...)
			res.Lines = append(res.Lines, dupeLine(g)...)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if res.Events, err = d.GetEvents(ctx, playerID); err != nil {
		return nil, err
	}
	if res.Snapshot, err = d.GetState(ctx, playerID); err != nil {
		return nil, err
	}
	return &res, nil
}

func festivalSource(id int64, kind string, i int) GrantSource {
	return GrantSource{Diamonds: ledger.Festival, Gold: "festival",
		Ref: fmt.Sprintf("festival:%d:%s:%d", id, kind, i), ItemFrom: "event"}
}

// closeFestivals closes every festival that has ended: its board's places are
// paid by letter, and each lord is sent what they left unclaimed.
func closeFestivals(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	due, err := q.EventsToSettle(ctx, now)
	if err != nil {
		return fmt.Errorf("festivals to close: %w", err)
	}
	for _, e := range due {
		f, err := festivalOf(e)
		if err != nil {
			return err
		}
		n, err := d.closeFestival(ctx, &f)
		if err != nil {
			return fmt.Errorf("close festival %d: %w", f.ID, err)
		}
		if err := q.MarkEventSettled(ctx, sqlcdb.MarkEventSettledParams{ID: f.ID, At: &now}); err != nil {
			return fmt.Errorf("mark festival %d closed: %w", f.ID, err)
		}
		if d.Log != nil {
			d.Log.Info("festival closed", "id", f.ID, "template", f.Tpl.ID, "lords", n)
		}
	}
	return nil
}

// closeFestival pays one festival's board and leftovers. Every letter carries
// an idempotency key, so a close that died half way runs again safely.
func (d Deps) closeFestival(ctx context.Context, f *Festival) (int, error) {
	q := sqlcdb.New(d.Pool)
	rows, err := q.EventStandings(ctx, f.ID)
	if err != nil {
		return 0, fmt.Errorf("standings: %w", err)
	}
	all, err := q.EventDeeds(ctx, f.ID)
	if err != nil {
		return 0, fmt.Errorf("festival deeds: %w", err)
	}
	progress := map[uuid.UUID]map[string]int64{}
	for _, r := range all {
		if progress[r.PlayerID] == nil {
			progress[r.PlayerID] = map[string]int64{}
		}
		progress[r.PlayerID][r.Deed] = r.Value
	}
	// The board's own rule: a banned lord holds no place, and is sent nothing.
	counts := func(r sqlcdb.EventStandingsRow) bool { return !r.IsBot && r.State == "active" }
	placed := 0
	for _, r := range rows {
		if counts(r) && r.PointsMilli > 0 {
			placed++
		}
	}
	place := 0
	for _, r := range rows {
		if !counts(r) {
			continue
		}
		row := sqlcdb.AppPlayerEvent{PlayerID: r.PlayerID, EventID: r.EventID, PointsMilli: r.PointsMilli,
			Tasks: r.Tasks, Milestones: r.Milestones}
		myPlace := 0
		if r.PointsMilli > 0 {
			place++
			myPlace = place
		}
		if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			return d.closeFestivalFor(ctx, sqlcdb.New(tx), f, row, progress[r.PlayerID], myPlace, placed)
		}); err != nil {
			return 0, err
		}
	}
	return placed, nil
}

// closeFestivalFor sends one lord their place's reward and their leftovers.
func (d Deps) closeFestivalFor(ctx context.Context, q *sqlcdb.Queries, f *Festival,
	row sqlcdb.AppPlayerEvent, progress map[string]int64, place, lords int) error {
	if g := liveops.PlaceReward(f.Tpl.Ranks, place); g != nil {
		if _, err := d.SendMail(ctx, q, row.PlayerID, MailDraft{
			Kind: "event", Sender: f.Tpl.Name,
			Title: fmt.Sprintf("%s: %s place", f.Tpl.Name, ordinal(place)),
			Body: fmt.Sprintf("The %s has closed, and you finished %s of %d with %s points. The Crown sends your prize.",
				f.Tpl.Name, ordinal(place), lords, rewards.Group(row.PointsMilli/1000)),
			Attachments: *g, IdemKey: fmt.Sprintf("festival:%d:place", f.ID),
		}); err != nil {
			return err
		}
	}
	tasks, ms := festivalOpen(f, row, progress)
	if len(tasks)+len(ms) == 0 {
		return nil
	}
	var left gameconfig.RewardBundle
	var names []string
	for _, i := range tasks {
		left = rewards.Merge(left, f.Tpl.Tasks[i].Grant)
		names = append(names, f.Tpl.Tasks[i].Name)
	}
	for _, i := range ms {
		left = rewards.Merge(left, f.Tpl.Milestones[i].Grant)
		names = append(names, fmt.Sprintf("%s points", rewards.Group(f.Tpl.Milestones[i].At)))
	}
	if _, err := q.ClaimEventRewards(ctx, sqlcdb.ClaimEventRewardsParams{
		PlayerID: row.PlayerID, EventID: f.ID, Tasks: int32(liveops.Mask(tasks)), Milestones: int32(liveops.Mask(ms)),
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // claimed in the meantime
		}
		return fmt.Errorf("mark leftovers: %w", err)
	}
	_, err := d.SendMail(ctx, q, row.PlayerID, MailDraft{
		Kind: "event", Sender: f.Tpl.Name,
		Title: fmt.Sprintf("What the %s still owed you", f.Tpl.Name),
		Body: fmt.Sprintf("The %s closed before you claimed these: %s. They are yours all the same.",
			f.Tpl.Name, strings.Join(names, ", ")),
		Attachments: left, IdemKey: fmt.Sprintf("festival:%d:left", f.ID),
	})
	return err
}

// ordinal is 1st, 2nd, 3rd, 4th ... 11th, 12th, 13th, 21st.
func ordinal(n int) string {
	suffix := "th"
	switch {
	case n%100 >= 11 && n%100 <= 13:
	case n%10 == 1:
		suffix = "st"
	case n%10 == 2:
		suffix = "nd"
	case n%10 == 3:
		suffix = "rd"
	}
	return fmt.Sprintf("%d%s", n, suffix)
}

// ScheduleFestival puts a festival on the calendar, frozen as its template
// stands now. It may not share a moment with another.
func (d Deps) ScheduleFestival(ctx context.Context, templateID string, startsAt time.Time, by, note string) (*sqlcdb.AdminLiveEvent, error) {
	t := d.Config.LiveOps.Events.Template(templateID)
	if t == nil {
		return nil, fmt.Errorf("%w: no festival %q", ErrNotFound, templateID)
	}
	frozen, err := json.Marshal(t)
	if err != nil {
		return nil, fmt.Errorf("freeze festival: %w", err)
	}
	ends := startsAt.Add(time.Duration(t.Days) * 24 * time.Hour)
	var row sqlcdb.AdminLiveEvent
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		// One scheduling at a time, so two cannot both see an empty window.
		if _, err := tx.Exec(ctx, "LOCK TABLE admin.live_events IN SHARE ROW EXCLUSIVE MODE"); err != nil {
			return fmt.Errorf("lock the calendar: %w", err)
		}
		q := sqlcdb.New(tx)
		n, err := q.CountOverlappingEvents(ctx, sqlcdb.CountOverlappingEventsParams{StartsAt: startsAt, EndsAt: ends})
		if err != nil {
			return fmt.Errorf("overlap: %w", err)
		}
		if n > 0 {
			return ErrFestivalClash
		}
		row, err = q.InsertLiveEvent(ctx, sqlcdb.InsertLiveEventParams{
			TemplateID: templateID, StartsAt: startsAt, EndsAt: ends, Frozen: frozen, Note: note, CreatedBy: by,
		})
		return err
	})
	if err != nil {
		return nil, err
	}
	if d.Boosts != nil {
		_ = d.Boosts.Refresh(ctx)
	}
	return &row, nil
}

// RevokeFestival takes a festival off the calendar before it has closed. What
// its lords already claimed stays theirs; nothing more is paid.
func (d Deps) RevokeFestival(ctx context.Context, id int64, by string) (*sqlcdb.AdminLiveEvent, error) {
	at := d.Now()
	row, err := sqlcdb.New(d.Pool).RevokeLiveEvent(ctx, sqlcdb.RevokeLiveEventParams{ID: id, At: &at, By: &by})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if d.Boosts != nil {
		_ = d.Boosts.Refresh(ctx)
	}
	return &row, nil
}
