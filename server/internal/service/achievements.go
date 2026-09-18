package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The deeds (liveops.achievements): twenty-four, each in four tiers -- bronze,
// silver, gold, imperial -- on a lifetime count (a deed) or on the lord's state
// (a stat). Each tier pays when claimed; the fourth also gives its title.

// ErrDeedsEmpty is a claim with no tier reached and unclaimed.
var ErrDeedsEmpty = errors.New("there is no deed to claim")

// medals name the four tiers, as deeds.png paints them.
var medals = []string{"bronze", "silver", "gold", "imperial"}

// deedCategoryNames are deeds.png's seven medallions.
var deedCategoryNames = map[string]string{
	"work": "Labour", "war": "War", "kingdom": "Kingdom", "crown": "Crown",
	"scroll": "Duty", "laurel": "Fortune", "chest": "Trade",
}

// AchievementTierView is one tier of a deed.
type AchievementTierView struct {
	Tier    int            `json:"tier"`
	Medal   string         `json:"medal"`
	Target  int64          `json:"target"`
	Reached bool           `json:"reached"`
	Claimed bool           `json:"claimed"`
	Lines   []rewards.Line `json:"lines"`
}

// AchievementView is one deed as this lord stands to it.
type AchievementView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Icon     string `json:"icon"`
	Blurb    string `json:"blurb"`
	// The count it is judged on, and the next tier's target (0 once all four
	// are reached).
	Progress  int64 `json:"progress"`
	Next      int64 `json:"next"`
	Reached   int   `json:"reached"`
	Claimed   int   `json:"claimed"`
	Claimable int   `json:"claimable"`
	// The highest medal claimed ("" before the first).
	Medal string                `json:"medal"`
	Tiers []AchievementTierView `json:"tiers"`
	// The fourth tier's title, as it reads when worn.
	Title string `json:"title"`
}

// AchievementCategoryView is one medallion: its deeds, and how many tiers of
// them are claimed of all there are.
type AchievementCategoryView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Deeds     int    `json:"deeds"`
	Claimed   int    `json:"claimed"`
	Tiers     int    `json:"tiers"`
	Claimable int    `json:"claimable"`
}

// AchievementsView is the DEEDS page.
type AchievementsView struct {
	Categories   []AchievementCategoryView `json:"categories"`
	Achievements []AchievementView         `json:"achievements"`
	Claimable    int                       `json:"claimable"`
	// Tiers claimed of every medal, bronze to imperial.
	Medals []int `json:"medals"`
}

// AchievementClaim is what a claim paid.
type AchievementClaim struct {
	Lines        []rewards.Line    `json:"lines"`
	Achievements *AchievementsView `json:"achievements"`
	Snapshot     *Snapshot         `json:"snapshot"`
}

// deedProgress is every deed's count for a lord: lifetime deeds and stats.
func (d Deps) deedProgress(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (map[string]int64, error) {
	rows, err := q.ListDeeds(ctx, sqlcdb.ListDeedsParams{PlayerID: p.ID, Scope: deeds.ScopeLife, Period: 0})
	if err != nil {
		return nil, fmt.Errorf("lifetime deeds: %w", err)
	}
	life := make(map[string]int64, len(rows))
	for _, r := range rows {
		life[r.Deed] = r.Value
	}
	out := map[string]int64{}
	var mastered, collection *int64
	for _, a := range d.Config.LiveOps.Achievements {
		if a.Deed != "" {
			out[a.ID] = life[a.Deed]
			continue
		}
		switch a.Stat {
		case gameconfig.StatLevel:
			out[a.ID] = int64(p.Level)
		case gameconfig.StatMight:
			out[a.ID] = p.Might
		case gameconfig.StatMasteries:
			if mastered == nil {
				var n int64
				if ms := d.Config.Jobs.Milestones; len(ms) > 0 {
					c, err := q.CountMastered(ctx, sqlcdb.CountMasteredParams{PlayerID: p.ID, Collects: ms[len(ms)-1].Collects})
					if err != nil {
						return nil, fmt.Errorf("mastered jobs: %w", err)
					}
					n = int64(c)
				}
				mastered = &n
			}
			out[a.ID] = *mastered
		case gameconfig.StatCollection:
			if collection == nil {
				c, err := q.CountCollection(ctx, p.ID)
				if err != nil {
					return nil, fmt.Errorf("collection: %w", err)
				}
				n := int64(c)
				collection = &n
			}
			out[a.ID] = *collection
		}
	}
	return out, nil
}

// achievementClaims is the tiers a lord has claimed, per deed.
func achievementClaims(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (map[string]int, error) {
	rows, err := q.ListAchievementClaims(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("deed claims: %w", err)
	}
	out := make(map[string]int, len(rows))
	for _, r := range rows {
		out[r.Achievement] = int(r.Claimed)
	}
	return out, nil
}

// achievementsClaimable is how many tiers wait to be claimed: the badge.
func (d Deps) achievementsClaimable(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) int {
	progress, err := d.deedProgress(ctx, q, p)
	if err != nil {
		return 0
	}
	claims, err := achievementClaims(ctx, q, p.ID)
	if err != nil {
		return 0
	}
	n := 0
	for _, a := range d.Config.LiveOps.Achievements {
		n += max(0, liveops.Reached(a.Tiers, progress[a.ID])-claims[a.ID])
	}
	return n
}

// GetAchievements is the DEEDS page.
func (d Deps) GetAchievements(ctx context.Context, playerID uuid.UUID) (*AchievementsView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	return d.achievementsView(ctx, q, p)
}

func (d Deps) achievementsView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*AchievementsView, error) {
	progress, err := d.deedProgress(ctx, q, p)
	if err != nil {
		return nil, err
	}
	claims, err := achievementClaims(ctx, q, p.ID)
	if err != nil {
		return nil, err
	}
	lo := d.Config.LiveOps
	out := &AchievementsView{Categories: []AchievementCategoryView{}, Achievements: []AchievementView{},
		Medals: make([]int, len(medals))}
	cats := map[string]*AchievementCategoryView{}
	for _, id := range gameconfig.AchievementCategories {
		out.Categories = append(out.Categories, AchievementCategoryView{ID: id, Name: deedCategoryNames[id]})
	}
	for i := range out.Categories {
		cats[out.Categories[i].ID] = &out.Categories[i]
	}
	for _, a := range lo.Achievements {
		n := progress[a.ID]
		reached := liveops.Reached(a.Tiers, n)
		claimed := min(claims[a.ID], len(a.Tiers))
		v := AchievementView{
			ID: a.ID, Name: a.Name, Category: a.Category, Icon: a.Icon, Blurb: a.Blurb,
			Progress: n, Reached: reached, Claimed: claimed, Claimable: max(0, reached-claimed),
			Tiers: make([]AchievementTierView, 0, len(a.Tiers)),
		}
		if reached < len(a.Tiers) {
			v.Next = a.Tiers[reached]
		}
		if claimed > 0 {
			v.Medal = medals[min(claimed, len(medals))-1]
		}
		if c := d.Config.Cosmetic(a.Title); c != nil {
			v.Title = c.Text
		}
		for t, target := range a.Tiers {
			v.Tiers = append(v.Tiers, AchievementTierView{
				Tier: t + 1, Medal: medals[min(t, len(medals)-1)], Target: target,
				Reached: t < reached, Claimed: t < claimed,
				Lines: rewards.Lines(d.Config, achievementTierGrant(lo, a, t), rewards.Resolved{}),
			})
		}
		out.Achievements = append(out.Achievements, v)
		out.Claimable += v.Claimable
		for t := 0; t < claimed && t < len(out.Medals); t++ {
			out.Medals[t]++
		}
		if c := cats[a.Category]; c != nil {
			c.Deeds++
			c.Tiers += len(a.Tiers)
			c.Claimed += claimed
			c.Claimable += v.Claimable
		}
	}
	return out, nil
}

// achievementTierGrant is what a deed's tier pays: the tier's reward, and at
// the fourth the deed's title.
func achievementTierGrant(lo gameconfig.LiveOpsConfig, a gameconfig.Achievement, t int) gameconfig.RewardBundle {
	var g gameconfig.RewardBundle
	if t < len(lo.AchievementTiers) {
		g = lo.AchievementTiers[t]
	}
	if t == len(a.Tiers)-1 && a.Title != "" {
		g = rewards.Merge(g, gameconfig.RewardBundle{Cosmetics: []string{a.Title}})
	}
	return g
}

// ClaimAchievements claims every tier reached and unclaimed of one deed (id
// given) or of every deed (id empty).
func (d Deps) ClaimAchievements(ctx context.Context, playerID uuid.UUID, id string) (*AchievementClaim, error) {
	res := AchievementClaim{Lines: []rewards.Line{}}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		lo := d.Config.LiveOps
		progress, err := d.deedProgress(ctx, q, p)
		if err != nil {
			return err
		}
		claims, err := achievementClaims(ctx, q, p.ID)
		if err != nil {
			return err
		}
		found, paid := false, 0
		for _, a := range lo.Achievements {
			if id != "" && a.ID != id {
				continue
			}
			found = true
			from := claims[a.ID]
			to := liveops.Reached(a.Tiers, progress[a.ID])
			if to <= from {
				continue
			}
			if _, err := q.ClaimAchievement(ctx, sqlcdb.ClaimAchievementParams{
				PlayerID: p.ID, Achievement: a.ID, FromTier: int16(from), ToTier: int16(to),
			}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrAlreadyClaimed
				}
				return fmt.Errorf("claim %s: %w", a.ID, err)
			}
			for t := from; t < to; t++ {
				g, err := d.grantBundle(ctx, q, &p, achievementTierGrant(lo, a, t), GrantSource{
					Diamonds: ledger.Achievement, Gold: "achievement",
					Ref: fmt.Sprintf("achievement:%s:%d", a.ID, t+1), ItemFrom: "reward",
				})
				if err != nil {
					return err
				}
				res.Lines = append(res.Lines, g.Lines...)
				res.Lines = append(res.Lines, dupeLine(g)...)
				paid++
			}
		}
		switch {
		case !found:
			return ErrNotFound
		case paid == 0:
			return ErrDeedsEmpty
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if res.Achievements, err = d.GetAchievements(ctx, playerID); err != nil {
		return nil, err
	}
	if res.Snapshot, err = d.GetState(ctx, playerID); err != nil {
		return nil, err
	}
	return &res, nil
}

// backfillLifeDeeds raises every lord's lifetime counters to what the records
// kept before the counters began show: raids and their spoils from the
// battles, collects and the energy they cost from each job's count, upgrades
// and holdings from their levels, the market and the kingdom from the gold
// ledger, letters from the mailbag, the calendar from its place. Raised, never
// summed, so it runs again harmlessly; a deed with no older record counts from
// the day its counter began.
func backfillLifeDeeds(ctx context.Context, d Deps, _ time.Time) error {
	q := sqlcdb.New(d.Pool)
	n, err := q.BackfillLifeDeeds(ctx)
	if err != nil {
		return fmt.Errorf("backfill deeds: %w", err)
	}
	cost := map[string]int64{}
	for _, j := range d.Config.Jobs.Jobs {
		cost[j.ID] = j.EnergyCost
	}
	rows, err := q.JobCollects(ctx)
	if err != nil {
		return fmt.Errorf("job collects: %w", err)
	}
	energy := map[uuid.UUID]int64{}
	for _, r := range rows {
		energy[r.PlayerID] += r.Collects * cost[r.JobID]
	}
	var ids []uuid.UUID
	var names []string
	var vals []int64
	flush := func() error {
		if len(ids) == 0 {
			return nil
		}
		err := q.RaiseLifeDeeds(ctx, sqlcdb.RaiseLifeDeedsParams{PlayerIds: ids, Deeds: names, Vals: vals})
		ids, names, vals = ids[:0], names[:0], vals[:0]
		return err
	}
	for id, e := range energy {
		if e <= 0 {
			continue
		}
		ids, names, vals = append(ids, id), append(names, string(deeds.Energy)), append(vals, e)
		if len(ids) >= 500 {
			if err := flush(); err != nil {
				return fmt.Errorf("raise energy: %w", err)
			}
		}
	}
	if err := flush(); err != nil {
		return fmt.Errorf("raise energy: %w", err)
	}
	if d.Log != nil {
		d.Log.Info("lifetime deeds backfilled", "rows", n, "energy_lords", len(energy))
	}
	return nil
}
