package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Look is how a lord looks to everyone else: what they wear, resolved for
// drawing, and Royal Favour's seal (the level number is theirs alone). Embedded
// in every view that shows another lord -- a raid card, a revenge card, a
// ranking, a kingdom's lords, a battle report -- so one lord looks the same on
// every screen.
//
// Read straight off the worn columns. They are kept true by UnwearLapsed (the
// cosmetics_lapse job, and at once after a refund or a lapsed patronage), which
// is what lets a list of fifty lords skip a check per row.
type Look struct {
	Worn    Worn `json:"worn"`
	VIPSeal bool `json:"vip_seal"`
}

// lookOf resolves a lord's worn columns and Royal Favour points.
func lookOf(cfg *gameconfig.Bundle, frame, title, color, crest *string, vipPoints int64) Look {
	resolve := func(id *string, kind string) *gameconfig.Cosmetic {
		if id == nil {
			return nil
		}
		c := cfg.Cosmetic(*id)
		if c == nil || c.Kind != kind {
			return nil
		}
		return c
	}
	var w Worn
	if c := resolve(frame, gameconfig.CosmeticFrame); c != nil {
		w.Frame = c.Art
	}
	if c := resolve(title, gameconfig.CosmeticTitle); c != nil {
		w.Title = c.Text
	}
	if c := resolve(color, gameconfig.CosmeticNameColor); c != nil {
		w.Color = c.Color
	}
	if c := resolve(crest, gameconfig.CosmeticCrest); c != nil {
		w.Crest = c.Art
	}
	return Look{Worn: w, VIPSeal: vipPoints > 0 && cfg.VIPLevel(vipPoints) > 0}
}

// defaultCosmetics is every cosmetic everyone owns: never taken off.
func defaultCosmetics(cfg *gameconfig.Bundle) []string {
	var out []string
	for _, c := range cfg.Cosmetics.Items {
		if c.DefaultOwned {
			out = append(out, c.ID)
		}
	}
	return out
}

// unwearLapsed takes off what lords wear but no longer hold: one lord, or
// (nil) everyone. It says how many lords it changed.
func (d Deps) unwearLapsed(ctx context.Context, q *sqlcdb.Queries, playerID *uuid.UUID, now time.Time) (int64, error) {
	n, err := q.UnwearLapsed(ctx, sqlcdb.UnwearLapsedParams{
		Defaults: defaultCosmetics(d.Config), Now: now, PlayerID: playerID,
	})
	if err != nil {
		return 0, fmt.Errorf("take off lapsed cosmetics: %w", err)
	}
	return n, nil
}
