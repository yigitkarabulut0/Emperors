package admin

import (
	"context"
	"fmt"
	"math/bits"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/cart"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// PlayerDetail is everything the per-player panel shows.
type PlayerDetail struct {
	PlayerRow
	XP                int64  `json:"xp"`
	XPToNext          int64  `json:"xp_to_next"`
	StatPointsUnspent int    `json:"stat_points_unspent"`
	StatEnergy        int    `json:"stat_energy"`
	StatAttack        int    `json:"stat_attack"`
	StatDefense       int    `json:"stat_defense"`
	Energy            int64  `json:"energy"`
	Treasury          string `json:"treasury"`
	SoldierSlots      int    `json:"soldier_slots"`
	ActionSeq         int64  `json:"action_seq"`
	Created           string `json:"created"`
	// Diamonds a refund took back that had already been spent, repaid from the
	// next diamonds the player earns. Zero for nearly everyone.
	DiamondDebt int64 `json:"diamond_debt"`

	LuckBP        int32   `json:"luck_bp"`
	LuckExpiresAt *string `json:"luck_expires_at"`

	// The tier odds this player faces right now, and what they would face at the
	// luck being previewed. Both come from the same function the roller uses, so
	// the panel cannot promise odds the game will not deliver.
	OddsNow    []items.TierOdd `json:"odds_now"`
	OddsAtLuck []items.TierOdd `json:"odds_at_luck"`
	PreviewBP  int32           `json:"preview_bp"`

	// Where the lord stands in the daily loop (retention.json).
	Loop PlayerLoop `json:"loop"`

	Audit []AuditEntry `json:"audit"`
}

// PlayerLoop is the daily loop as one lord stands in it: what support needs to
// answer "where is my cart", "why did my run break", "is the guide stuck".
type PlayerLoop struct {
	CartStock    int    `json:"cart_stock"`
	CartCap      int    `json:"cart_cap"`
	CartNextIn   int64  `json:"cart_next_in"`
	CartsOpened  int    `json:"carts_opened"`
	CalendarPos  int    `json:"calendar_pos"`
	CalendarRuns int    `json:"calendar_cycles"`
	Streak       int    `json:"streak"`
	LastClaim    string `json:"last_claim"`
	RoadClaimed  int    `json:"road_claimed"`
	RoadTotal    int    `json:"road_total"`
	// The guide's step id, or "" once it is over; Skipped when it was skipped.
	GuideStep    string `json:"guide_step"`
	GuideIndex   int    `json:"guide_index"`
	GuideSteps   int    `json:"guide_steps"`
	GuideSkipped bool   `json:"guide_skipped"`
	GoldenToday  int    `json:"golden_today"`
	WinbackAt    string `json:"winback_at"`
}

// GetPlayerDetail loads one player, their current tier odds, and their history.
//
// previewBP is the luck value the operator is considering; the response carries
// the odds at that value beside the odds today, so the decision is made against
// real numbers rather than a basis-point abstraction nobody can picture.
func (s *Service) GetPlayerDetail(ctx context.Context, playerID uuid.UUID, previewBP int32) (*PlayerDetail, error) {
	q := sqlcdb.New(s.Pool)
	p, err := q.AdminGetPlayer(ctx, playerID)
	if err != nil {
		return nil, ErrNotFound
	}

	cfg := s.Config.Get()
	shop := cfg.Items.Shop
	level := int(p.Level)

	// The luck actually in force: an expired override is not applied, matching
	// exactly what loadEffects does on the game side.
	live := int64(0)
	if p.LuckBp != 0 && (p.LuckExpiresAt == nil || p.LuckExpiresAt.After(s.now())) {
		live = int64(p.LuckBp)
	}

	var expires *string
	if p.LuckExpiresAt != nil {
		v := p.LuckExpiresAt.UTC().Format("2006-01-02 15:04")
		expires = &v
	}

	out := &PlayerDetail{
		PlayerRow:         *playerRow(p),
		XP:                p.Xp,
		XPToNext:          cfg.XPToNext(level),
		StatPointsUnspent: int(p.StatPointsUnspent),
		StatEnergy:        int(p.StatEnergy),
		StatAttack:        int(p.StatAttack),
		StatDefense:       int(p.StatDefense),
		Energy:            p.EnergyMilli / 1000,
		Treasury:          fmt.Sprint(p.TreasuryGold),
		SoldierSlots:      int(p.SoldierSlots),
		DiamondDebt:       p.DiamondDebt,
		ActionSeq:         p.ActionSeq,
		Created:           p.CreatedAt.UTC().Format("2006-01-02"),
		LuckBP:            p.LuckBp,
		LuckExpiresAt:     expires,
		PreviewBP:         previewBP,
		OddsNow: items.TierOdds(cfg, shop.BaseWeights,
			items.EffectiveLuckCoef(shop.LuckCoef, live), level),
		OddsAtLuck: items.TierOdds(cfg, shop.BaseWeights,
			items.EffectiveLuckCoef(shop.LuckCoef, int64(previewBP)), level),
	}

	out.Loop = playerLoop(cfg, p, s.now())

	rows, err := q.AuditForSubject(ctx, sqlcdb.AuditForSubjectParams{
		Subject: strPtr(playerID.String()), Limit: 20,
	})
	if err == nil {
		for _, r := range rows {
			subject := ""
			if r.Subject != nil {
				subject = *r.Subject
			}
			out.Audit = append(out.Audit, AuditEntry{
				ID: r.ID, Admin: r.AdminName, Action: r.Action, Subject: subject,
				Note: r.Note, At: r.CreatedAt.UTC().Format("2006-01-02 15:04:05"),
			})
		}
	}
	return out, nil
}

func strPtr(s string) *string { return &s }

// playerLoop reads the daily loop off the lord's row, with the game's own
// arithmetic (game/cart) for the yard, so the panel says what the game would.
func playerLoop(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, now time.Time) PlayerLoop {
	c := cfg.Retention.Cart
	interval := time.Duration(c.IntervalSeconds) * time.Second
	y := cart.Settle(cart.Yard{Stock: int(p.CartStock), At: p.CartAt}, c.Cap, interval, now)
	l := PlayerLoop{
		CartStock: y.Stock, CartCap: c.Cap, CartsOpened: int(p.CartsOpened),
		CartNextIn:  int64(cart.NextIn(y, c.Cap, interval, now) / time.Second),
		CalendarPos: int(p.CalendarPos), CalendarRuns: int(p.CalendarCycle), Streak: int(p.DailyStreak),
		RoadClaimed: bits.OnesCount32(uint32(p.RoadClaimed)), RoadTotal: len(cfg.Retention.Road.Milestones),
		GuideSteps: len(cfg.Retention.Guide.Steps), GuideIndex: int(p.GuideStep), GuideSkipped: p.GuideSkipped,
	}
	if p.DailyClaimedOn.Valid {
		l.LastClaim = p.DailyClaimedOn.Time.Format("2006-01-02")
	}
	if p.GuideDoneAt == nil && int(p.GuideStep) < len(cfg.Retention.Guide.Steps) {
		l.GuideStep = cfg.Retention.Guide.Steps[p.GuideStep].ID
	}
	if p.FrenzyDay.Valid && p.FrenzyDay.Time.Format("2006-01-02") == now.UTC().Add(
		time.Duration(p.ResetOffsetMinutes)*time.Minute).Format("2006-01-02") {
		l.GoldenToday = int(p.FrenzyUsed)
	}
	if p.WinbackAt != nil {
		l.WinbackAt = p.WinbackAt.UTC().Format("2006-01-02 15:04")
	}
	return l
}
