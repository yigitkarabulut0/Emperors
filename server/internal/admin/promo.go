package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Promo codes: made here, redeemed in the game (service/promo.go), delivered
// by the Royal Mail. A code gives only what play gives too -- App Review 3.1.1
// forbids a code that unlocks what is sold -- so no cosmetics, and diamonds up
// to the balance's promo cap. Anyone who knows a code can redeem it, so making
// one is a designer's call.

// PromoCreate is one code from the panel.
type PromoCreate struct {
	Code   string                  `json:"code"`
	Note   string                  `json:"note"`
	Reward gameconfig.RewardBundle `json:"reward"`
	// How many lords may redeem it; 0 is no limit.
	MaxUses int `json:"max_uses"`
	// Days until it stops working; 0 is never.
	ExpiresDays int `json:"expires_days"`
}

// PromoRow is a code as the panel lists it.
type PromoRow struct {
	Code      string                  `json:"code"`
	Note      string                  `json:"note"`
	Reward    gameconfig.RewardBundle `json:"reward"`
	MaxUses   int32                   `json:"max_uses"`
	Uses      int32                   `json:"uses"`
	StartsAt  time.Time               `json:"starts_at"`
	ExpiresAt *time.Time              `json:"expires_at"`
	// live, used_up, expired, disabled or scheduled.
	State     string    `json:"state"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
}

// Redemption is one lord who redeemed a code.
type Redemption struct {
	PlayerID   string    `json:"player_id"`
	Username   string    `json:"username"`
	RedeemedAt time.Time `json:"redeemed_at"`
}

// checkPromoReward holds a code's reward to what a code may give.
func checkPromoReward(cfg *gameconfig.Bundle, r gameconfig.RewardBundle) error {
	if r.Empty() {
		return fmt.Errorf("%w: a code must give something", ErrOutOfRange)
	}
	if len(r.Cosmetics) > 0 {
		return fmt.Errorf("%w: a code cannot give cosmetics — App Review forbids codes that unlock what is sold", ErrOutOfRange)
	}
	if max := cfg.Rewards.Promo.MaxDiamonds; r.Diamonds > max {
		return fmt.Errorf("%w: a code gives at most %d diamonds", ErrOutOfRange, max)
	}
	if problems := cfg.CheckReward(r, false); len(problems) > 0 {
		return fmt.Errorf("%w: %s", ErrOutOfRange, strings.Join(problems, "; "))
	}
	return nil
}

// CreatePromo makes a code.
func (s *Service) CreatePromo(ctx context.Context, who *Identity, in PromoCreate) (*PromoRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	code := service.NormalizePromo(in.Code)
	if len(code) < 4 || len(code) > 20 {
		return nil, fmt.Errorf("%w: a code is 4 to 20 letters and digits", ErrOutOfRange)
	}
	if in.MaxUses < 0 || in.ExpiresDays < 0 || in.ExpiresDays > 365 {
		return nil, fmt.Errorf("%w: uses and days cannot be negative, and a code lasts a year at most", ErrOutOfRange)
	}
	cfg := s.Config.Get()
	if err := checkPromoReward(cfg, in.Reward); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(in.Reward)
	if err != nil {
		return nil, err
	}
	now := s.now()
	var expires *time.Time
	if in.ExpiresDays > 0 {
		e := now.AddDate(0, 0, in.ExpiresDays)
		expires = &e
	}
	row, err := sqlcdb.New(s.Pool).CreatePromoCode(ctx, sqlcdb.CreatePromoCodeParams{
		Code: code, Note: strings.TrimSpace(in.Note), Reward: raw, MaxUses: int32(in.MaxUses),
		StartsAt: now, ExpiresAt: expires, CreatedBy: who.Username,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%w: the code %s already exists", ErrOutOfRange, code)
	}
	if err != nil {
		return nil, fmt.Errorf("create promo: %w", err)
	}
	s.Audit(ctx, who, "promo.create", code, nil, map[string]any{"reward": in.Reward, "max_uses": in.MaxUses,
		"expires_days": in.ExpiresDays}, in.Note)
	out := promoRow(row, now)
	return &out, nil
}

// Promos lists codes, newest first.
func (s *Service) Promos(ctx context.Context) ([]PromoRow, error) {
	rows, err := sqlcdb.New(s.Pool).ListPromoCodes(ctx, 200)
	if err != nil {
		return nil, fmt.Errorf("promos: %w", err)
	}
	now := s.now()
	out := make([]PromoRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, promoRow(r, now))
	}
	return out, nil
}

// DisablePromo stops a code working. Letters it already sent stay.
func (s *Service) DisablePromo(ctx context.Context, who *Identity, code, note string) (*PromoRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	code = service.NormalizePromo(code)
	row, err := sqlcdb.New(s.Pool).DisablePromoCode(ctx, sqlcdb.DisablePromoCodeParams{Code: code, At: ptrTime(s.now())})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("disable promo: %w", err)
	}
	s.Audit(ctx, who, "promo.disable", code, nil, nil, note)
	out := promoRow(row, s.now())
	return &out, nil
}

// PromoRedemptions lists who redeemed a code.
func (s *Service) PromoRedemptions(ctx context.Context, code string) ([]Redemption, error) {
	rows, err := sqlcdb.New(s.Pool).ListPromoRedemptions(ctx, sqlcdb.ListPromoRedemptionsParams{
		Code: service.NormalizePromo(code), Lim: 200,
	})
	if err != nil {
		return nil, fmt.Errorf("redemptions: %w", err)
	}
	out := make([]Redemption, 0, len(rows))
	for _, r := range rows {
		out = append(out, Redemption{PlayerID: r.PlayerID.String(), Username: r.Username, RedeemedAt: r.RedeemedAt})
	}
	return out, nil
}

func promoRow(r sqlcdb.AdminPromoCode, now time.Time) PromoRow {
	out := PromoRow{Code: r.Code, Note: r.Note, MaxUses: r.MaxUses, Uses: r.Uses, StartsAt: r.StartsAt,
		ExpiresAt: r.ExpiresAt, CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt, State: "live"}
	_ = json.Unmarshal(r.Reward, &out.Reward)
	switch {
	case r.DisabledAt != nil:
		out.State = "disabled"
	case r.ExpiresAt != nil && !r.ExpiresAt.After(now):
		out.State = "expired"
	case r.MaxUses > 0 && r.Uses >= r.MaxUses:
		out.State = "used_up"
	case r.StartsAt.After(now):
		out.State = "scheduled"
	}
	return out
}

func ptrTime(t time.Time) *time.Time { return &t }
