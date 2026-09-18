package admin

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The moderation desk (service/social_desk.go): the halls, what has been
// reported in them, and the crown's two answers.
//
// Reading the queue is an ANALYST's: it is the job of looking. Hiding a line or
// silencing a tongue is a MODERATOR's, and every one of them is audited with
// the line's own id -- a silence with no name against it is how a hall becomes
// a rumour about the crown.

// ModQueue is what is waiting to be judged.
func (s *Service) ModQueue(ctx context.Context, who *Identity, limit int) (*service.ModQueueView, error) {
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
	v, err := d.ModQueue(ctx, int32(limit))
	return v, deskError(err)
}

// ModContext is the room around one line.
func (s *Service) ModContext(ctx context.Context, who *Identity, id uuid.UUID, span int) ([]service.ChatLine, error) {
	if !AtLeast(who.Role, "analyst") {
		return nil, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return nil, err
	}
	v, err := d.ModContext(ctx, id, int64(span))
	return v, deskError(err)
}

// HideLine takes a line down, or puts it back.
func (s *Service) HideLine(ctx context.Context, who *Identity, id uuid.UUID, hide bool, note string) error {
	if !AtLeast(who.Role, "moderator") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	if err := d.HideLine(ctx, id, hide, who.Username); err != nil {
		return deskError(err)
	}
	action := "chat.restore"
	if hide {
		action = "chat.hide"
	}
	s.Audit(ctx, who, action, id.String(), nil, map[string]any{"hidden": hide}, note)
	return nil
}

// MuteLord silences a tongue for a while.
func (s *Service) MuteLord(ctx context.Context, who *Identity, playerID uuid.UUID, minutes int, reason, note string) (time.Time, error) {
	if !AtLeast(who.Role, "moderator") {
		return time.Time{}, ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return time.Time{}, err
	}
	if reason == "" {
		reason = "the crown's hand"
	}
	until, err := d.MuteLord(ctx, playerID, minutes, reason, who.Username)
	if err != nil {
		return time.Time{}, deskError(err)
	}
	s.Audit(ctx, who, "chat.mute", playerID.String(), nil,
		map[string]any{"minutes": minutes, "until": until, "reason": reason}, note)
	return until, nil
}

// UnmuteLord lifts a silence.
func (s *Service) UnmuteLord(ctx context.Context, who *Identity, playerID uuid.UUID, note string) error {
	if !AtLeast(who.Role, "moderator") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	if err := d.UnmuteLord(ctx, playerID); err != nil {
		return deskError(err)
	}
	s.Audit(ctx, who, "chat.unmute", playerID.String(), nil, nil, note)
	return nil
}

// ClearLordReports answers every open report against a lord. It is the second
// queue's only answer of its own: what to DO about the lord -- a silence, a
// rename asked for by mail, nothing -- is done with the buttons that already
// exist, and this says the desk has looked.
func (s *Service) ClearLordReports(ctx context.Context, who *Identity, playerID uuid.UUID, note string) error {
	if !AtLeast(who.Role, "moderator") {
		return ErrForbidden
	}
	d, err := s.game()
	if err != nil {
		return err
	}
	n, err := d.ClearLordReports(ctx, playerID, who.Username)
	if err != nil {
		return deskError(err)
	}
	s.Audit(ctx, who, "lord.reports.clear", playerID.String(), nil,
		map[string]any{"answered": n}, note)
	return nil
}

// ModMutes is the trail of silences.
func (s *Service) ModMutes(ctx context.Context, who *Identity, limit int) ([]service.ModMute, error) {
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
	v, err := d.ModMutes(ctx, int32(limit))
	return v, deskError(err)
}
