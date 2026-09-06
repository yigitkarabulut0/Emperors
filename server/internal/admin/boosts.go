package admin

import (
	"context"
	"fmt"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// BoostRow is one server-wide event as the panel shows it.
type BoostRow struct {
	ID        int64  `json:"id"`
	Bucket    string `json:"bucket"`
	AmountBP  int64  `json:"amount_bp"`
	StartsAt  string `json:"starts_at"`
	EndsAt    string `json:"ends_at"`
	Note      string `json:"note"`
	CreatedBy string `json:"created_by"`
	Live      bool   `json:"live"`
	Revoked   bool   `json:"revoked"`
}

// Boostable is one bucket an event may drive, described for the panel.
type Boostable struct {
	Bucket string `json:"bucket"`
	Label  string `json:"label"`
	Help   string `json:"help"`
	CapBP  int64  `json:"cap_bp"`
}

// BoostableBuckets describes what an event may change, and what it cannot.
//
// The list is short on purpose. Energy regeneration is absent because it is the
// one ceiling that bounds the whole gold supply: max energy decides how long you
// can be away, regen decides how much you can earn in a day. A "double energy
// weekend" is not a generous event, it is an uncapped mint -- and if it is ever
// really wanted it belongs in a balance publish, which is versioned, reviewed
// and rollback-able.
// The advertised cap is READ from the engine, never typed here.
//
// It was typed here once, and this list promised xp_bp could reach +200% while
// economy.Caps enforced +100% -- so the panel told an operator an event would be
// twice what it actually was, and ApplyBucket quietly clamped the difference
// away. Two numbers that must agree should not be two numbers.
func BoostableBuckets() []Boostable {
	return []Boostable{
		{gameconfig.BucketCollectIncome, "Job payout",
			"Gold from every collect. Shares its cap with job mastery and the Granary.",
			economy.Caps[economy.BucketCollectIncome]},
		{gameconfig.BucketXP, "Experience",
			"Experience from every source.",
			economy.Caps[economy.BucketXPGain]},
		{gameconfig.BucketLuck, "Fortune",
			"Shifts the tier ladder for shop stock and recruits. +10000 doubles the level coefficient.",
			gameconfig.MaxLuckBP},
	}
}

// capFor returns what a bucket is actually allowed to reach.
func capFor(bucket string) int64 {
	for _, b := range BoostableBuckets() {
		if b.Bucket == bucket {
			return b.CapBP
		}
	}
	return 0
}

// ListBoosts returns recent events, newest first.
func (s *Service) ListBoosts(ctx context.Context, limit int32) ([]BoostRow, error) {
	rows, err := sqlcdb.New(s.Pool).ListBoosts(ctx, limit)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := make([]BoostRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, BoostRow{
			ID: r.ID, Bucket: r.Bucket, AmountBP: r.AmountBp,
			StartsAt: r.StartsAt.UTC().Format("2006-01-02 15:04"),
			EndsAt:   r.EndsAt.UTC().Format("2006-01-02 15:04"),
			Note:     r.Note, CreatedBy: r.CreatedBy,
			Live:    r.RevokedAt == nil && r.StartsAt.Before(now) && r.EndsAt.After(now),
			Revoked: r.RevokedAt != nil,
		})
	}
	return out, nil
}

// CreateBoost starts a server-wide event.
//
// Designer and above: this changes the game for everyone at once, which is a
// larger act than adjusting one player's balance.
func (s *Service) CreateBoost(ctx context.Context, who *Identity,
	bucket string, amountBP int64, hours int, note string) (*BoostRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	if !service.IsBoostable(bucket) {
		return nil, fmt.Errorf("%w: %q cannot be driven by an event", ErrOutOfRange, bucket)
	}
	if hours < 1 || hours > 24*30 {
		return nil, fmt.Errorf("%w: an event runs between an hour and a month", ErrOutOfRange)
	}
	if amountBP == 0 {
		return nil, ErrNothingToDo
	}
	// Refuse what would be silently clamped. An operator who types 10,000,000
	// basis points has misunderstood something, and accepting it while quietly
	// applying a fraction is the worst of both answers -- they walk away
	// believing the event is a hundred times what it is.
	//
	// Negative is allowed down to -cap: ApplyBucket floors a total at zero, so a
	// nerf event can offset other bonuses but never take a payout below base.
	if cap := capFor(bucket); cap > 0 && (amountBP > cap || amountBP < -cap) {
		return nil, fmt.Errorf("%w: %s is capped at %d basis points, and %d would be clamped to it",
			ErrOutOfRange, bucket, cap, amountBP)
	}

	now := s.now()
	row, err := sqlcdb.New(s.Pool).CreateBoost(ctx, sqlcdb.CreateBoostParams{
		Bucket: bucket, AmountBp: amountBP,
		StartsAt: now, EndsAt: now.Add(time.Duration(hours) * time.Hour),
		Note: note, CreatedBy: who.Username,
	})
	if err != nil {
		return nil, err
	}

	// Live immediately rather than on the next poll. An operator who starts an
	// event and then checks whether it is running should not be told "not yet".
	if s.Boosts != nil {
		_ = s.Boosts.Refresh(ctx)
	}
	s.Audit(ctx, who, "boost.create", fmt.Sprint(row.ID), nil,
		map[string]any{"bucket": bucket, "amount_bp": amountBP, "hours": hours}, note)

	return &BoostRow{
		ID: row.ID, Bucket: row.Bucket, AmountBP: row.AmountBp,
		StartsAt: row.StartsAt.UTC().Format("2006-01-02 15:04"),
		EndsAt:   row.EndsAt.UTC().Format("2006-01-02 15:04"),
		Note:     row.Note, CreatedBy: row.CreatedBy, Live: true,
	}, nil
}

// RevokeBoost ends an event early. It is never deleted: "why was everyone
// earning double on the 14th" has to stay answerable long afterwards.
func (s *Service) RevokeBoost(ctx context.Context, who *Identity, id int64) (*BoostRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	row, err := sqlcdb.New(s.Pool).RevokeBoost(ctx, sqlcdb.RevokeBoostParams{
		ID: id, RevokedBy: &who.Username,
	})
	if err != nil {
		return nil, ErrNotFound
	}
	if s.Boosts != nil {
		_ = s.Boosts.Refresh(ctx)
	}
	s.Audit(ctx, who, "boost.revoke", fmt.Sprint(id),
		map[string]any{"bucket": row.Bucket, "amount_bp": row.AmountBp}, nil, "")
	return &BoostRow{
		ID: row.ID, Bucket: row.Bucket, AmountBP: row.AmountBp,
		StartsAt: row.StartsAt.UTC().Format("2006-01-02 15:04"),
		EndsAt:   row.EndsAt.UTC().Format("2006-01-02 15:04"),
		Note:     row.Note, CreatedBy: row.CreatedBy, Revoked: true,
	}, nil
}
