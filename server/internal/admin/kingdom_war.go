package admin

import (
	"context"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Krallik Boss ve Savaslari (Wave 8) at the desk: the beasts standing against
// the realm's kingdoms, and the week's wars.
//
// An ANALYST's read, and only a read. Every number here is decided in the
// balance -- a beast's health, a blow's cost, what a win is worth -- where
// Validate holds it and the panel's Balance page is where a designer moves one.
//
// The figure to look at is the kill rate: boss.json's share is calibrated so a
// level-one beast falls in 65 to 80 per cent of cycles, and this is the same
// measurement taken in the wild.

// KingdomWar reads the desk over a window in hours (24 by default).
func (s *Service) KingdomWar(ctx context.Context, who *Identity, hours int) (*service.WarDeskView, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	return d.KingdomWarDesk(ctx, hours)
}
