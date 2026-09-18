package admin

import (
	"context"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// PvE ve derinlik (Wave 7) at the desk: the campaign's road across the realm,
// the roads' expeditions, the anvil's work and the tree's picks.
//
// An ANALYST's read, and only a read: there is no lever here at all. Every
// number this desk shows is decided in the balance -- a stage's garrison, a
// field's wages, a talent's rank -- where Validate holds it, and the panel's
// own Balance page is where a designer changes one.

// Depth reads the desk over a window in hours (24 by default).
func (s *Service) Depth(ctx context.Context, who *Identity, hours int) (*service.DepthView, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.Depth(ctx, hours)
}
