package admin

import (
	"context"
	"fmt"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
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

	LuckBP        int32   `json:"luck_bp"`
	LuckExpiresAt *string `json:"luck_expires_at"`

	// The tier odds this player faces right now, and what they would face at the
	// luck being previewed. Both come from the same function the roller uses, so
	// the panel cannot promise odds the game will not deliver.
	OddsNow    []items.TierOdd `json:"odds_now"`
	OddsAtLuck []items.TierOdd `json:"odds_at_luck"`
	PreviewBP  int32           `json:"preview_bp"`

	Audit []AuditEntry `json:"audit"`
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
