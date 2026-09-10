package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Badges is what the rail and the pills flag as waiting for the player: work
// that is finished and not yet claimed, or a decision somebody else is waiting
// on. Nothing on the rail said any of it, so a finished quest, a revenge strike
// and a lord asking to join all waited until the player happened to open the
// right tab.
//
// Counts, never amounts: the tabs say what is waiting when they are opened.
type Badges struct {
	Quests   int  `json:"quests"`   // done and not claimed
	Daily    bool `json:"daily"`    // the day's reward can be claimed
	Revenge  int  `json:"revenge"`  // raiders there is still a day to answer
	Requests int  `json:"requests"` // lords asking to join (a king or captain's)
}

// GetBadges gathers them. Each part that fails is left at zero rather than
// failing the whole: a missing badge costs a nudge, not a screen.
func (d Deps) GetBadges(ctx context.Context, playerID uuid.UUID) (*Badges, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("badges: %w", err)
	}
	b := &Badges{}
	if qv, err := d.GetQuests(ctx, playerID); err == nil {
		for _, x := range qv.Quests {
			if x.Done && !x.Claimed {
				b.Quests++
			}
		}
	}
	if dv, err := d.GetDaily(ctx, playerID); err == nil {
		b.Daily = dv.Claimable
	}
	// One per raider, as the Attack tab lists them: one strike settles every
	// token held against a lord. Allies are left out, as the list leaves them.
	if rows, err := q.ListRevenge(ctx, playerID); err == nil {
		seen := map[uuid.UUID]bool{}
		for _, r := range rows {
			if p.KingdomID != nil && r.TargetKingdomID != nil && *p.KingdomID == *r.TargetKingdomID {
				continue
			}
			if !seen[r.TargetID] {
				seen[r.TargetID] = true
				b.Revenge++
			}
		}
	}
	if p.KingdomID != nil && (p.KingdomRole == "king" || p.KingdomRole == "marshal") {
		if rows, err := q.ListRequestsForKingdom(ctx, *p.KingdomID); err == nil {
			b.Requests = len(rows)
		}
	}
	return b, nil
}
