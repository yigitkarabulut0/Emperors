package admin

import (
	"context"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Rekabet's desk (service/pvp_desk.go): the arena's ladder, the bounty board's
// escrow and the Throne. The rules live beside the game; here are the roles and
// the audit.

// ArenaLadder is the ladder, for the panel.
func (s *Service) ArenaLadder(ctx context.Context, who *Identity, limit int) (*service.ArenaDeskView, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	v, err := d.ArenaDesk(ctx, int32(limit))
	return v, deskError(err)
}

// Bounties is the board's escrow, what it has burned, and the pairs worth a
// second look.
func (s *Service) Bounties(ctx context.Context, who *Identity, limit int) (*service.BountyDeskView, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	v, err := d.BountyDesk(ctx, int32(limit))
	return v, deskError(err)
}

// RevokeBounty withdraws a price and gives the whole remainder back.
//
// The fee stays burned: it left the economy when the price was set, and a
// withdrawal is not a refund of the crier.
func (s *Service) RevokeBounty(ctx context.Context, who *Identity, id uuid.UUID, note string) (int64, error) {
	if !AtLeast(who.Role, "designer") {
		return 0, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return 0, err
	}
	n, err := d.RevokeBounty(ctx, id)
	if err != nil {
		return 0, deskError(err)
	}
	s.Audit(ctx, who, "bounty.revoke", id.String(), nil, map[string]any{"refunded": n}, note)
	return n, nil
}

// Throne is the reign, the week's race and the reigns before it.
func (s *Service) Throne(ctx context.Context, who *Identity) (*service.ThroneDeskView, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	v, err := d.ThroneDesk(ctx)
	return v, deskError(err)
}

// SettleThrone crowns the closed week by hand, for an operator who has just
// fixed whatever stopped the job. Idempotent: the week is claimed in
// admin.period_closes and the reign's own key refuses a second crowning.
func (s *Service) SettleThrone(ctx context.Context, who *Identity, note string) error {
	if !AtLeast(who.Role, "designer") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	if err := d.SettleThroneNow(ctx); err != nil {
		return deskError(err)
	}
	s.Audit(ctx, who, "throne.settle", "", nil, nil, note)
	return nil
}
