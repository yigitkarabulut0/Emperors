package admin

import (
	"context"
	"fmt"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Point is one day of a series.
type Point struct {
	Day   string `json:"day"`
	Count int64  `json:"count"`
}

// Analytics is the population view: who signed up, who is playing, who is here.
type Analytics struct {
	Registrations []Point       `json:"registrations"`
	Active        []Point       `json:"active"`
	LevelBands    []Point       `json:"level_bands"`
	Online        []PlayerBrief `json:"online"`
	OnlineWindow  int           `json:"online_window_minutes"`
	Days          int           `json:"days"`
}

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
	return out, nil
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
