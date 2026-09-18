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
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The steward's guide through the first ten minutes (retention.guide). The
// server holds the step, so a lord who closes the game mid-step comes back to
// it; each step is done by doing the thing (the deed is counted where it is
// done, as every deed is), and SKIP ends it at any step. Finishing pays the
// Heir's frame. Every lord who existed before the guide has it over already.

var (
	// ErrGuideMoved is an advance naming a step the lord is not on.
	ErrGuideMoved = errors.New("the guide has moved on")
	// ErrGuideNotReady is an advance on a step not yet done.
	ErrGuideNotReady = errors.New("that step is not done yet")
)

// BanditPreview is the guide's fight as its card shows it before it is fought.
type BanditPreview struct {
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Level  int64  `json:"level"`
	Might  int64  `json:"might"`
	Purse  int64  `json:"purse"`
}

// GuideView is the guide on the snapshot: {active: false} once it is over.
type GuideView struct {
	Active   bool           `json:"active"`
	Step     string         `json:"step,omitempty"`
	Index    int            `json:"index,omitempty"`
	Count    int            `json:"count,omitempty"`
	Ready    bool           `json:"ready,omitempty"`
	Tab      string         `json:"tab,omitempty"`
	Target   string         `json:"target,omitempty"`
	MinLevel int            `json:"min_level,omitempty"`
	Title    string         `json:"title,omitempty"`
	Text     string         `json:"text,omitempty"`
	Done     string         `json:"done,omitempty"`
	Tap      bool           `json:"tap,omitempty"`
	Bandit   *BanditPreview `json:"bandit,omitempty"`
}

// GuideAdvance is a step done, with what the next step's beginning paid.
type GuideAdvance struct {
	Guide    GuideView      `json:"guide"`
	Lines    []rewards.Line `json:"lines"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// BanditFight is the guide's fight against Karel the Bandit.
type BanditFight struct {
	Won            bool           `json:"won"`
	Replay         *combat.Replay `json:"replay"`
	Gold           int64          `json:"gold"`
	XPGained       int64          `json:"xp_gained"`
	DiamondsGained int64          `json:"diamonds_gained"`
	Lines          []rewards.Line `json:"lines"`
	Guide          GuideView      `json:"guide"`
	Snapshot       *Snapshot      `json:"snapshot"`
}

func guideOver(p sqlcdb.AppPlayer, steps int) bool {
	return p.GuideDoneAt != nil || int(p.GuideStep) >= steps
}

// guideView is the lord's guide as it stands. It reads the step's deed only
// while a guide is running, so the snapshot of every lord past it costs nothing.
func (d Deps) guideView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) GuideView {
	g := d.Config.Retention.Guide
	if guideOver(p, len(g.Steps)) {
		return GuideView{}
	}
	i := int(p.GuideStep)
	s := g.Steps[i]
	v := GuideView{
		Active: true, Step: s.ID, Index: i, Count: len(g.Steps),
		Tab: s.Tab, Target: s.Target, MinLevel: s.MinLevel,
		Title: s.Title, Text: s.Text, Done: s.Done, Tap: s.Kind == gameconfig.GuideTap,
	}
	ready, err := d.guideReady(ctx, q, p, s)
	v.Ready = err == nil && ready
	if s.Kind == gameconfig.GuideFight {
		b := g.Bandit
		v.Bandit = &BanditPreview{Name: b.Name, Avatar: b.Avatar, Level: b.Level,
			Might: army.UnitMight(b.Attack, army.EffectiveHP(d.Config, b.HP, b.Defense, b.Level))}
		if eff, err := d.loadEffects(ctx, q, p); err == nil {
			v.Bandit.Purse = rewards.Resolve(d.Config, b.Grant, int(p.Level), rewards.PermanentOnly(eff.Bonuses)).Gold
		}
	}
	return v
}

// guideReady says whether a step is done. A tap step is done by tapping on; the
// fight is done only by fighting it.
func (d Deps) guideReady(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, s gameconfig.GuideStep) (bool, error) {
	switch s.Kind {
	case gameconfig.GuideTap:
		return true, nil
	case gameconfig.GuideLevel:
		return int(p.Level) >= s.Level, nil
	case gameconfig.GuideDeed:
		n, err := q.LifeDeed(ctx, sqlcdb.LifeDeedParams{PlayerID: p.ID, Deed: s.Deed})
		if err != nil {
			return false, fmt.Errorf("guide deed: %w", err)
		}
		return n >= s.Count, nil
	case gameconfig.GuideWorn:
		n, err := q.CountHeroEquipped(ctx, p.ID)
		if err != nil {
			return false, fmt.Errorf("guide gear: %w", err)
		}
		return n > 0, nil
	}
	return false, nil
}

// AdvanceGuide moves the guide on from a step that is done. The step is named
// so a double tap, or two devices, move it once.
func (d Deps) AdvanceGuide(ctx context.Context, playerID uuid.UUID, step string) (*GuideAdvance, error) {
	var lines []rewards.Line
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		g := d.Config.Retention.Guide
		if guideOver(p, len(g.Steps)) || g.Steps[p.GuideStep].ID != step {
			return ErrGuideMoved
		}
		cur := g.Steps[p.GuideStep]
		ready, err := d.guideReady(ctx, q, p, cur)
		if err != nil {
			return err
		}
		if !ready {
			return ErrGuideNotReady
		}
		lines, err = d.moveGuide(ctx, q, &p, d.Now())
		return err
	})
	if err != nil {
		return nil, err
	}
	return d.guideAnswer(ctx, playerID, lines)
}

// moveGuide takes the guide from the lord's step to the next, paying what the
// next step's beginning pays (the steward's purse) or, past the last, the
// finish. The caller holds the lock and has checked the step is done.
func (d Deps) moveGuide(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, now time.Time) ([]rewards.Line, error) {
	g := d.Config.Retention.Guide
	from := p.GuideStep
	next := int(from) + 1
	var doneAt *time.Time
	if next >= len(g.Steps) {
		doneAt = &now
	}
	moved, err := q.MoveGuide(ctx, sqlcdb.MoveGuideParams{
		ID: p.ID, Step: int16(next), DoneAt: doneAt, Skipped: false, FromStep: from,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrGuideMoved
		}
		return nil, fmt.Errorf("move the guide: %w", err)
	}
	*p = moved

	if doneAt != nil {
		gr, err := d.grantBundle(ctx, q, p, g.Finish, GrantSource{
			Diamonds: ledger.Guide, Gold: "guide", Ref: "guide:finish", ItemFrom: "tutorial",
		})
		if err != nil {
			return nil, err
		}
		return gr.Lines, nil
	}
	s := g.Steps[next]
	if !s.Purse || g.PurseMax <= 0 {
		return nil, nil
	}
	price, err := d.guidePrice(ctx, q, *p, s)
	if err != nil || price <= p.Gold {
		return nil, err
	}
	short := min(price-p.Gold, g.PurseMax)
	gr, err := d.grantBundle(ctx, q, p, gameconfig.RewardBundle{Gold: short}, GrantSource{
		Diamonds: ledger.Guide, Gold: "guide", Ref: "guide:" + s.ID,
	})
	if err != nil {
		return nil, err
	}
	return gr.Lines, nil
}

// guidePrice is what the step's first purchase costs the lord now: the
// market's cheapest piece of gear, or the cheapest family upgrade.
func (d Deps) guidePrice(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer, s gameconfig.GuideStep) (int64, error) {
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return 0, err
	}
	var cheapest int64
	take := func(price int64) {
		if price > 0 && (cheapest == 0 || price < cheapest) {
			cheapest = price
		}
	}
	switch s.Deed {
	case "buys":
		windowID, _ := d.shopWindow()
		st, err := q.UpsertShopWindow(ctx, sqlcdb.UpsertShopWindowParams{
			PlayerID: p.ID, WindowID: windowID, LuckBp: int32(eff.LuckBP),
		})
		if err != nil {
			return 0, fmt.Errorf("guide shop: %w", err)
		}
		for _, o := range d.rollOffers(p.ID, st, int(p.Level), eff.ShopDiscount) {
			if !o.Purchased {
				take(o.Price)
			}
		}
	case "upgrades":
		ups, err := q.ListUpgrades(ctx, p.ID)
		if err != nil {
			return 0, fmt.Errorf("guide upgrades: %w", err)
		}
		levels := map[string]int{}
		for _, u := range ups {
			levels[u.UpgradeID] = int(u.Level)
		}
		for _, u := range d.Config.Estates.Upgrades {
			if c, ok := u.Cost(levels[u.ID]); ok {
				take(c)
			}
		}
	}
	return cheapest, nil
}

// SkipGuide ends the guide where it stands, without its finish.
func (d Deps) SkipGuide(ctx context.Context, playerID uuid.UUID) (*GuideAdvance, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if guideOver(p, len(d.Config.Retention.Guide.Steps)) {
			return nil
		}
		now := d.Now()
		if _, err := q.MoveGuide(ctx, sqlcdb.MoveGuideParams{
			ID: p.ID, Step: p.GuideStep, DoneAt: &now, Skipped: true, FromStep: p.GuideStep,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("skip the guide: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.guideAnswer(ctx, playerID, nil)
}

func (d Deps) guideAnswer(ctx context.Context, playerID uuid.UUID, lines []rewards.Line) (*GuideAdvance, error) {
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	if lines == nil {
		lines = []rewards.Line{}
	}
	return &GuideAdvance{Guide: snap.Guide, Lines: lines, Snapshot: snap}, nil
}

// banditArmy is Karel the Bandit: one fighter, not a lord.
func banditArmy(b gameconfig.BanditConfig) combat.Army {
	return combat.Army{
		PlayerID: "bandit", Name: b.Name, Avatar: b.Avatar, Level: b.Level,
		Units: []combat.Combatant{{ID: "bandit", Name: b.Name, IsHero: true,
			Attack: b.Attack, Defense: b.Defense, Speed: b.Speed, HP: b.HP}},
	}
}

// FightBandit is the guide's one fight: the lord's own army against Karel, a
// real battle, the first of the guide's seeds the lord wins. Nobody is robbed:
// Karel is not a lord, the purse is the balance's, and no battle row is kept
// (a raid's history is lords against lords). A lord who cannot win it in any
// of the seeds is shown the first fight, lost, and the guide goes on without
// the purse -- it must never leave a new lord stuck.
func (d Deps) FightBandit(ctx context.Context, playerID uuid.UUID) (*BanditFight, error) {
	mine, err := d.GetArmy(ctx, playerID)
	if err != nil {
		return nil, err
	}
	var res BanditFight
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		g := d.Config.Retention.Guide
		if guideOver(p, len(g.Steps)) || g.Steps[p.GuideStep].Kind != gameconfig.GuideFight {
			return ErrGuideMoved
		}
		b := g.Bandit
		me, them := myArmy(p, mine), banditArmy(b)
		theirMight := army.UnitMight(b.Attack, army.EffectiveHP(d.Config, b.HP, b.Defense, b.Level))
		var chosen *combat.Replay
		for i := 0; i < b.Seeds; i++ {
			rng := game.SeedForString(d.ShopSecret, p.ID.String(), uint64(i), 0xBA4D)
			r := combat.Simulate(d.Config, rng, rng.Uint64(), me, them)
			r.AttackerMight, r.DefenderMight = mine.Totals.Might, theirMight
			if chosen == nil {
				chosen = r
			}
			if r.Winner == combat.SideAttacker {
				chosen = r
				break
			}
		}
		res.Replay = chosen
		res.Won = chosen != nil && chosen.Winner == combat.SideAttacker
		if res.Won {
			gr, err := d.grantBundle(ctx, q, &p, b.Grant, GrantSource{
				Diamonds: ledger.Guide, Gold: "guide", Ref: "guide:bandit", ItemFrom: "tutorial",
			})
			if err != nil {
				return err
			}
			res.Lines, res.Gold, res.XPGained, res.DiamondsGained = gr.Lines, gr.Gold, gr.XP, gr.Diamonds+gr.LevelDiamonds
		}
		_, err = d.moveGuide(ctx, q, &p, d.Now())
		return err
	})
	if err != nil {
		return nil, err
	}
	if res.Lines == nil {
		res.Lines = []rewards.Line{}
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	res.Guide, res.Snapshot = snap.Guide, snap
	return &res, nil
}
