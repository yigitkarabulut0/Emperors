package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// AwayView is what happened to a player's city while they were gone: the
// raids on it, what they took, what holding them off paid, and whether a
// revenge strike is waiting. A defender used to come back to less gold and
// nothing saying why unless they went looking in the Attack tab's history.
type AwayView struct {
	Raids        int64 `json:"raids"`
	GoldLost     int64 `json:"gold_lost"`
	RansomEarned int64 `json:"ransom_earned"`
	Revenge      int   `json:"revenge"`
}

// awayWindow is as far back as the summary looks, however long the absence:
// a raid a week old is history, not news.
const awayWindow = 7 * 24 * time.Hour

// GetAway sums the raids since the moment the client last saw the game.
func (d Deps) GetAway(ctx context.Context, playerID uuid.UUID, since time.Time) (*AwayView, error) {
	if floor := d.Now().Add(-awayWindow); since.Before(floor) {
		since = floor
	}
	q := sqlcdb.New(d.Pool)
	row, err := q.CountRaidsSince(ctx, sqlcdb.CountRaidsSinceParams{PlayerID: playerID, Since: since})
	if err != nil {
		return nil, fmt.Errorf("away: %w", err)
	}
	v := &AwayView{Raids: row.Raids, GoldLost: row.GoldLost, RansomEarned: row.RansomEarned}
	if b, err := d.GetBadges(ctx, playerID); err == nil {
		v.Revenge = b.Revenge
	}
	return v, nil
}
