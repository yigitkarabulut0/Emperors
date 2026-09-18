package admin

import (
	"context"
	"fmt"
	"math"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/experiments"
)

// A/B tests are balance data (commerce.experiments): which offers are arms,
// and whether the test runs. A lord's arm is a keyed hash, so it is never
// stored; what is stored is the moment an arm's offer was first shown to them
// (app.experiment_exposures), and a conversion is that lord buying the arm's
// product afterwards. Production purchases only, as on the billing desk.

// ExperimentResult is one test and how each of its arms is doing.
type ExperimentResult struct {
	ID     string      `json:"id"`
	Active bool        `json:"active"`
	Note   string      `json:"note"`
	Arms   []ArmResult `json:"arms"`
}

// ArmResult is one arm. Conversion is in basis points of the lords shown it;
// revenue per lord in hundredths of a cent, so a small figure keeps its
// digits. Z is the two-proportion z statistic against the control (the first
// arm), zero for the control itself; Significant is |z| at or past 1.96, a
// 95% two-sided test.
type ArmResult struct {
	ID           string  `json:"id"`
	Product      string  `json:"product"`
	Weight       int     `json:"weight"`
	PriceCents   int64   `json:"price_cents"`
	Exposed      int64   `json:"exposed"`
	Converted    int64   `json:"converted"`
	RevenueCents int64   `json:"revenue_cents"`
	ConversionBP int64   `json:"conversion_bp"`
	PerLordCC    int64   `json:"per_lord_centicents"`
	Z            float64 `json:"z"`
	Significant  bool    `json:"significant"`
}

// Experiments lists every test in the live balance with its results.
func (s *Service) Experiments(ctx context.Context) ([]ExperimentResult, error) {
	cfg := s.Config.Get()
	q := sqlcdb.New(s.Pool)
	out := []ExperimentResult{}
	for _, e := range cfg.Commerce.Experiments {
		rows, err := q.ExperimentResults(ctx, e.ID)
		if err != nil {
			return nil, fmt.Errorf("experiment %s: %w", e.ID, err)
		}
		byArm := map[string]sqlcdb.ExperimentResultsRow{}
		for _, r := range rows {
			byArm[r.Arm] = r
		}
		res := ExperimentResult{ID: e.ID, Active: e.Active, Note: e.Note, Arms: []ArmResult{}}
		for _, a := range e.Arms {
			r := byArm[a.ID]
			ar := ArmResult{ID: a.ID, Product: a.Product, Weight: a.Weight,
				Exposed: r.Exposed, Converted: r.Converted, RevenueCents: r.RevenueCents}
			if pr := cfg.Product(a.Product); pr != nil {
				ar.PriceCents = pr.USDCents
			}
			if r.Exposed > 0 {
				ar.ConversionBP = r.Converted * 10000 / r.Exposed
				ar.PerLordCC = r.RevenueCents * 100 / r.Exposed
			}
			res.Arms = append(res.Arms, ar)
		}
		if len(res.Arms) > 0 {
			c := res.Arms[0]
			for i := 1; i < len(res.Arms); i++ {
				z := experiments.ZScore(c.Exposed, c.Converted, res.Arms[i].Exposed, res.Arms[i].Converted)
				res.Arms[i].Z = math.Round(z*100) / 100
				res.Arms[i].Significant = math.Abs(z) >= 1.96
			}
		}
		out = append(out, res)
	}
	return out, nil
}
