package admin

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Point is one day of a series.
type Point struct {
	Day   string `json:"day"`
	Count int64  `json:"count"`
}

// Analytics is the population view: who signed up, who is playing, who is here,
// who came back, and what the phone saw them do.
type Analytics struct {
	Registrations []Point       `json:"registrations"`
	Active        []Point       `json:"active"`
	LevelBands    []Point       `json:"level_bands"`
	Online        []PlayerBrief `json:"online"`
	OnlineWindow  int           `json:"online_window_minutes"`
	Days          int           `json:"days"`
	Retention     []Cohort      `json:"retention"`
	Events        []EventCount  `json:"events"`
	Screens       []EventCount  `json:"screens"`
	Sessions      []Point       `json:"sessions"`
	// The rolled-up days of the window (the kpi_rollup job), through yesterday.
	KPIs []KPIDay `json:"kpis"`
}

// KPIDay is one UTC day's figures from app.daily_kpi. Revenue is Production
// only, in US cents; ARPDAU is net takings over the lords who played, in
// hundredths of a cent, and conversion is payers over them in basis points.
type KPIDay struct {
	Day             string `json:"day"`
	DAU             int32  `json:"dau"`
	NewLords        int32  `json:"new_lords"`
	Payers          int32  `json:"payers"`
	Purchases       int32  `json:"purchases"`
	GrossCents      int64  `json:"gross_cents"`
	RefundCents     int64  `json:"refund_cents"`
	NetCents        int64  `json:"net_cents"`
	ARPDAUCentiCent int64  `json:"arpdau_centicents"`
	ConversionBP    int64  `json:"conversion_bp"`
	DiamondsEarned  int64  `json:"diamonds_earned"`
	DiamondsBought  int64  `json:"diamonds_bought"`
	DiamondsSpent   int64  `json:"diamonds_spent"`
}

// Cohort is the players who joined on one UTC day and how many came back. A
// day that has not come yet for the cohort is null, not zero: "nobody came
// back" and "it is too soon to say" are different answers.
type Cohort struct {
	Day  string `json:"day"`
	Size int64  `json:"size"`
	D1   *int64 `json:"d1"`
	D7   *int64 `json:"d7"`
	D30  *int64 `json:"d30"`
}

// EventCount is one event name, or one screen, over the window.
type EventCount struct {
	Name    string `json:"name"`
	Count   int64  `json:"count"`
	Players int64  `json:"players"`
}

// sessionBands names SessionLengths' bands, in its order.
var sessionBands = []string{"under 1 min", "1-3 min", "3-10 min", "10-30 min", "30 min +"}

// PlayerBrief is a row in the online list.
type PlayerBrief struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Gold     string `json:"gold"`
	Diamonds int64  `json:"diamonds"`
	State    string `json:"state"`
	Seen     string `json:"seen"`
}

// GetAnalytics answers "how is the game doing" with series rather than totals.
//
// Four tiles cannot tell you whether yesterday was good. A line can.
func (s *Service) GetAnalytics(ctx context.Context, days, onlineMinutes int) (*Analytics, error) {
	if days < 1 || days > 90 {
		days = 30
	}
	if onlineMinutes < 1 || onlineMinutes > 1440 {
		onlineMinutes = 15
	}
	q := sqlcdb.New(s.Pool)
	now := s.now()
	// Initialised, not nil: an empty series must serialise as [] so the panel can
	// map over it without a guard at every use.
	out := &Analytics{
		Days: days, OnlineWindow: onlineMinutes,
		Registrations: []Point{}, Active: []Point{},
		LevelBands: []Point{}, Online: []PlayerBrief{},
		Retention: []Cohort{}, Events: []EventCount{}, Screens: []EventCount{}, Sessions: []Point{}, KPIs: []KPIDay{},
	}

	regs, err := q.RegistrationsDaily(ctx, sqlcdb.RegistrationsDailyParams{Now: now, Days: int32(days)})
	if err != nil {
		return nil, err
	}
	for _, r := range regs {
		out.Registrations = append(out.Registrations, Point{r.Day.Time.Format("2006-01-02"), r.Count})
	}

	act, err := q.ActiveDaily(ctx, sqlcdb.ActiveDailyParams{Now: now, Days: int32(days)})
	if err != nil {
		return nil, err
	}
	for _, r := range act {
		out.Active = append(out.Active, Point{r.Day.Time.Format("2006-01-02"), r.Count})
	}

	bands, err := q.LevelBands(ctx)
	if err != nil {
		return nil, err
	}
	for _, r := range bands {
		out.LevelBands = append(out.LevelBands, Point{fmt.Sprintf("%d-%d", r.Band, r.Band+9), r.Count})
	}

	online, err := q.OnlineNow(ctx, now.Add(-time.Duration(onlineMinutes)*time.Minute))
	if err != nil {
		return nil, err
	}
	for _, r := range online {
		out.Online = append(out.Online, PlayerBrief{
			ID: r.ID.String(), Username: r.Username, Name: r.DisplayName,
			Level: int(r.Level), Gold: fmt.Sprint(r.Gold), Diamonds: r.Diamonds,
			State: r.State, Seen: r.LastSeenAt.UTC().Format("15:04:05"),
		})
	}

	since := now.AddDate(0, 0, -days)
	today := time.Date(now.UTC().Year(), now.UTC().Month(), now.UTC().Day(), 0, 0, 0, 0, time.UTC)
	cohorts, err := q.RetentionCohorts(ctx, pgtype.Date{Time: since.UTC(), Valid: true})
	if err != nil {
		return nil, err
	}
	for _, r := range cohorts {
		out.Retention = append(out.Retention, cohortRow(r, today))
	}

	events, err := q.EventCounts(ctx, since)
	if err != nil {
		return nil, err
	}
	for _, r := range events {
		out.Events = append(out.Events, EventCount{Name: r.Name, Count: r.Events, Players: r.Players})
	}
	screens, err := q.ScreenCounts(ctx, since)
	if err != nil {
		return nil, err
	}
	for _, r := range screens {
		out.Screens = append(out.Screens, EventCount{Name: r.Screen, Count: r.Views, Players: r.Players})
	}
	sessions, err := q.SessionLengths(ctx, since)
	if err != nil {
		return nil, err
	}
	out.Sessions = sessionPoints(sessions)
	kpis, err := q.ListKPIDays(ctx, pgtype.Date{Time: since.UTC(), Valid: true})
	if err != nil {
		return nil, err
	}
	for _, k := range kpis {
		out.KPIs = append(out.KPIs, kpiDay(k))
	}
	return out, nil
}

func kpiDay(k sqlcdb.AppDailyKpi) KPIDay {
	v := KPIDay{Day: k.Day.Time.Format("2006-01-02"), DAU: k.Dau, NewLords: k.NewLords, Payers: k.Payers,
		Purchases: k.Purchases, GrossCents: k.GrossCents, RefundCents: k.RefundCents,
		NetCents: k.GrossCents - k.RefundCents, DiamondsEarned: k.DiamondsEarned,
		DiamondsBought: k.DiamondsBought, DiamondsSpent: k.DiamondsSpent}
	if k.Dau > 0 {
		v.ARPDAUCentiCent = v.NetCents * 100 / int64(k.Dau)
		v.ConversionBP = int64(k.Payers) * 10000 / int64(k.Dau)
	}
	return v
}

// cohortRow reads one cohort, leaving each return day null until it has come:
// a cohort that joined yesterday has no day-7 answer yet, and a zero there
// would read as a cohort that never came back.
func cohortRow(r sqlcdb.RetentionCohortsRow, today time.Time) Cohort {
	c := Cohort{Day: r.Day.Time.Format("2006-01-02"), Size: r.Size}
	for _, k := range []struct {
		after int
		n     int64
		into  **int64
	}{{1, r.D1, &c.D1}, {7, r.D7, &c.D7}, {30, r.D30, &c.D30}} {
		if !r.Day.Time.AddDate(0, 0, k.after).After(today) {
			n := k.n
			*k.into = &n
		}
	}
	return c
}

// sessionPoints lays the bands out in order, every band present.
func sessionPoints(rows []sqlcdb.SessionLengthsRow) []Point {
	out := make([]Point, len(sessionBands))
	for i, name := range sessionBands {
		out[i] = Point{Day: name}
	}
	for _, r := range rows {
		if int(r.Band) >= 0 && int(r.Band) < len(out) {
			out[r.Band].Count = r.Sessions
		}
	}
	return out
}

// BrowseResult is one page of the player list.
type BrowseResult struct {
	Players []BrowseRow `json:"players"`
	Total   int64       `json:"total"`
	Offset  int         `json:"offset"`
	Limit   int         `json:"limit"`
}

// BrowseRow carries the columns the list actually shows.
type BrowseRow struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Gold     string `json:"gold"`
	Diamonds int64  `json:"diamonds"`
	State    string `json:"state"`
	IsBot    bool   `json:"is_bot"`
	LuckBP   int32  `json:"luck_bp"`
	Created  string `json:"created"`
	LastSeen string `json:"last_seen"`
}

// BrowseFilter is what the list is narrowed by.
type BrowseFilter struct {
	Q           string
	State       string
	IncludeBots bool
	MinLevel    int
	Sort        string
	Limit       int
	Offset      int
}

// sortKeys is the closed set the query switches on. A caller cannot reach the
// ORDER BY with anything not in here.
var sortKeys = map[string]bool{"last_seen": true, "created": true, "level": true, "gold": true}

// BrowsePlayers returns one page of players.
func (s *Service) BrowsePlayers(ctx context.Context, f BrowseFilter) (*BrowseResult, error) {
	if !sortKeys[f.Sort] {
		f.Sort = "last_seen"
	}
	if f.Limit < 1 || f.Limit > 200 {
		f.Limit = 50
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	rows, err := sqlcdb.New(s.Pool).BrowsePlayers(ctx, sqlcdb.BrowsePlayersParams{
		Q: f.Q, State: f.State, IncludeBots: f.IncludeBots,
		MinLevel: int32(f.MinLevel), Sort: f.Sort,
		Lim: int32(f.Limit), Off: int32(f.Offset),
	})
	if err != nil {
		return nil, err
	}
	out := &BrowseResult{Offset: f.Offset, Limit: f.Limit, Players: []BrowseRow{}}
	for _, r := range rows {
		out.Total = r.Total
		out.Players = append(out.Players, BrowseRow{
			ID: r.ID.String(), Username: r.Username, Name: r.DisplayName,
			Level: int(r.Level), Gold: fmt.Sprint(r.Gold), Diamonds: r.Diamonds,
			State: r.State, IsBot: r.IsBot, LuckBP: r.LuckBp,
			Created:  r.CreatedAt.UTC().Format("2006-01-02"),
			LastSeen: r.LastSeenAt.UTC().Format("2006-01-02 15:04"),
		})
	}
	return out, nil
}
