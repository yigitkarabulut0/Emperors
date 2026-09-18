package admin

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// DevTools are the game service's test hands (service/dev.go), given to the
// panel only by a server that is not production (cmd/api). Without them every
// dev action answers ErrNoDevTools.
type DevTools interface {
	DevTimeWarp(ctx context.Context, playerID uuid.UUID, hours int) error
	DevAddDeeds(ctx context.Context, playerID uuid.UUID, kind string, n int64) error
	DevRunJob(ctx context.Context, name string) error
	DevRestartGuide(ctx context.Context, playerID uuid.UUID) error
}

// ErrNoDevTools is a dev action on a server that has none: production.
var ErrNoDevTools = errors.New("dev tools are not on this server")

// DevAvailable reports whether this server has dev tools, for the panel to
// show them or not.
func (s *Service) DevAvailable() bool { return s.Dev != nil }

// DevTimeWarp moves a lord's clocks back, as if they had been away.
func (s *Service) DevTimeWarp(ctx context.Context, who *Identity, playerID uuid.UUID, hours int) error {
	if err := s.devAllowed(who); err != nil {
		return err
	}
	if err := s.Dev.DevTimeWarp(ctx, playerID, hours); err != nil {
		return devErr(err)
	}
	s.Audit(ctx, who, "dev.timewarp", playerID.String(), nil, map[string]any{"hours": hours}, "")
	return nil
}

// DevAddDeeds counts deeds for a lord as if they had done them.
func (s *Service) DevAddDeeds(ctx context.Context, who *Identity, playerID uuid.UUID, kind string, n int64) error {
	if err := s.devAllowed(who); err != nil {
		return err
	}
	if err := s.Dev.DevAddDeeds(ctx, playerID, kind, n); err != nil {
		return devErr(err)
	}
	s.Audit(ctx, who, "dev.deeds", playerID.String(), nil, map[string]any{"deed": kind, "n": n}, "")
	return nil
}

// DevRunJob runs a scheduled job now.
func (s *Service) DevRunJob(ctx context.Context, who *Identity, name string) error {
	if err := s.devAllowed(who); err != nil {
		return err
	}
	if err := s.Dev.DevRunJob(ctx, name); err != nil {
		return devErr(err)
	}
	s.Audit(ctx, who, "dev.run_job", name, nil, nil, "")
	return nil
}

// DevRestartGuide puts a lord back at the guide's first step, to walk it again.
func (s *Service) DevRestartGuide(ctx context.Context, who *Identity, playerID uuid.UUID) error {
	if err := s.devAllowed(who); err != nil {
		return err
	}
	if err := s.Dev.DevRestartGuide(ctx, playerID); err != nil {
		return devErr(err)
	}
	s.Audit(ctx, who, "dev.guide", playerID.String(), nil, nil, "")
	return nil
}

func (s *Service) devAllowed(who *Identity) error {
	if s.Dev == nil {
		return ErrNoDevTools
	}
	if !AtLeast(who.Role, "designer") {
		return ErrForbidden
	}
	return nil
}

// devErr turns the game service's refusals into the panel's.
func devErr(err error) error {
	switch {
	case errors.Is(err, service.ErrNotFound):
		return ErrNotFound
	case errors.Is(err, service.ErrDevRange):
		return fmt.Errorf("%w: %v", ErrOutOfRange, err)
	}
	return err
}
