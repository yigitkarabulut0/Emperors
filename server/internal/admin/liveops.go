package admin

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The live-ops desk (service/liveops_desk.go): the hourly schedule, the
// festival calendar and the season. The rules live beside the game; here are
// the roles and the audit.

// ErrNoGame is a live-ops call on a panel that was not handed the game.
var ErrNoGame = errors.New("the game service is not attached to this panel")

// game is the game service on the live balance, as a player's request sees it.
func (s *Service) game() (service.Deps, error) {
	if s.Game == nil {
		return service.Deps{}, ErrNoGame
	}
	d := *s.Game
	if s.Config != nil {
		d.Config = s.Config.Get()
	}
	return d, nil
}

// HourlySchedule is the day behind and the day ahead.
func (s *Service) HourlySchedule(ctx context.Context) ([]service.HourSlot, error) {
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.HourlySchedule(ctx)
}

// HourlyTable is the hourly table's rows as they stand, for the schedule's
// choices: every event with its chance and minutes, "none" included.
func (s *Service) HourlyTable() []service.HourlyInfo {
	out := []service.HourlyInfo{}
	if s.Config == nil {
		return out
	}
	for _, e := range s.Config.Get().LiveOps.Hourly.Table {
		out = append(out, service.HourlyInfo{ID: e.ID, Name: e.Name, Blurb: e.Blurb, Icon: e.Icon,
			Minutes: e.Minutes, BP: e.BP})
	}
	return out
}

// SetHour forces, skips or frees an hour to come.
func (s *Service) SetHour(ctx context.Context, who *Identity, hour int64, eventID, note string) error {
	if !AtLeast(who.Role, "designer") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	if err := d.SetHourlySlot(ctx, hour, strings.TrimSpace(eventID), who.Username, note); err != nil {
		return deskError(err)
	}
	s.Audit(ctx, who, "hourly.set", fmt.Sprint(hour), nil, map[string]any{"event": eventID}, note)
	return nil
}

// Festivals is the calendar.
func (s *Service) Festivals(ctx context.Context) (*service.FestivalCalendar, error) {
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.Festivals(ctx)
}

// ScheduleFestival puts a template on the calendar, startsIn hours from now
// (or at startsAt, "2006-01-02 15:04" UTC, when given).
func (s *Service) ScheduleFestival(ctx context.Context, who *Identity, templateID, startsAt string, startsIn int, note string) (int64, error) {
	if !AtLeast(who.Role, "designer") {
		return 0, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return 0, err
	}
	at := s.now().Add(time.Duration(startsIn) * time.Hour)
	if strings.TrimSpace(startsAt) != "" {
		t, err := time.ParseInLocation("2006-01-02 15:04", strings.TrimSpace(startsAt), time.UTC)
		if err != nil {
			return 0, fmt.Errorf("%w: the start is YYYY-MM-DD HH:MM, in UTC", ErrOutOfRange)
		}
		at = t
	}
	if startsIn < 0 || startsIn > 24*60 {
		return 0, fmt.Errorf("%w: a festival starts within sixty days", ErrOutOfRange)
	}
	row, err := d.ScheduleFestivalAt(ctx, templateID, at, who.Username, note)
	if err != nil {
		return 0, deskError(err)
	}
	s.Audit(ctx, who, "festival.schedule", fmt.Sprint(row.ID), nil,
		map[string]any{"template": templateID, "starts_at": row.StartsAt.UTC().Format(time.RFC3339),
			"ends_at": row.EndsAt.UTC().Format(time.RFC3339)}, note)
	return row.ID, nil
}

// RevokeFestival takes a festival off the calendar.
func (s *Service) RevokeFestival(ctx context.Context, who *Identity, id int64) error {
	if !AtLeast(who.Role, "designer") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	if _, err := d.RevokeFestival(ctx, id, who.Username); err != nil {
		return deskError(err)
	}
	s.Audit(ctx, who, "festival.revoke", fmt.Sprint(id), nil, nil, "")
	return nil
}

// FestivalBoard is a festival's board.
func (s *Service) FestivalBoard(ctx context.Context, id int64) ([]service.FestivalStanding, error) {
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.FestivalBoard(ctx, id)
}

// SeasonSummary is the running season.
func (s *Service) SeasonSummary(ctx context.Context) (*service.SeasonDesk, error) {
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.SeasonSummary(ctx)
}

// deskError turns the game's refusals into the panel's out-of-range, which it
// shows with their reason.
func deskError(err error) error {
	for _, e := range []error{service.ErrHourStarted, service.ErrHourTooFar, service.ErrNoSuchHourly,
		service.ErrFestivalPast, service.ErrFestivalClash,
		// Rekabet's own refusals (pvp_desk.go).
		service.ErrBountyGone, service.ErrNoThrone} {
		if errors.Is(err, e) {
			return fmt.Errorf("%w: %v", ErrOutOfRange, err)
		}
	}
	if errors.Is(err, service.ErrNotFound) {
		return fmt.Errorf("%w: %v", ErrNotFound, err)
	}
	return err
}
