package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/talents"
)

// TALENTS -- the Family tab's TALENTS sub-tab (talents.json).
//
// A point every three levels from ten, and one for each Legacy: twenty-seven
// against fifty-one ranks. What a rank does, it does through a channel the game
// already has, folded in where a Family upgrade is folded in (loadEffects), so
// there is no second place a percentage is applied.
//
// Taking it back costs gold, and the price doubles each time to a ceiling: a
// lord may change their mind, and a lord who changes it before every fight is
// paying for the privilege.

var (
	ErrTalentsLocked = errors.New("the talent tree opens later")
	ErrTalentUnknown = errors.New("no such talent")
	ErrTalentMaxed   = errors.New("that talent is at its last rank")
	ErrTalentPoints  = errors.New("you have no talent points left")
	ErrTalentShut    = errors.New("that tier of the branch is not open yet")
	ErrNoTalents     = errors.New("you have spent nothing to take back")
)

// TalentsView is the whole tree as one lord sees it.
type TalentsView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`

	// Given, spent and left. The client prints them and works out nothing.
	Points int64 `json:"points"`
	Spent  int64 `json:"spent"`
	Left   int64 `json:"left"`
	// When the next point arrives, and what it costs to take it all back.
	NextPointAt int64 `json:"next_point_at"`
	RespecCost  int64 `json:"respec_cost"`
	Respecs     int   `json:"respecs"`

	Branches []TalentBranchView `json:"branches"`
}

// TalentBranchView is one of the three.
type TalentBranchView struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Blurb   string       `json:"blurb"`
	Spent   int          `json:"spent"`
	Talents []TalentView `json:"talents"`
}

// TalentView is one node: what it is, what it is worth now, and whether this
// lord may buy into it.
type TalentView struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Tier  int    `json:"tier"`
	// The channel it feeds and what one rank is worth in that channel's units,
	// so the client can say "+1.5% attack" without a table of its own.
	Bucket  string `json:"bucket"`
	PerRank int64  `json:"per_rank"`
	Ranks   int    `json:"ranks"`
	Bought  int    `json:"bought"`
	// What it is doing for this lord right now (per_rank x bought).
	Now int64 `json:"now"`
	// The points this tier needs in its own branch, whether they are there, and
	// whether one more rank may be bought this second.
	Needs  int  `json:"needs"`
	Open   bool `json:"open"`
	CanBuy bool `json:"can_buy"`
}

// GetTalents paints the sub-tab.
func (d Deps) GetTalents(ctx context.Context, playerID uuid.UUID) (*TalentsView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("talents: %w", err)
	}
	spend, err := d.loadTalents(ctx, q, playerID)
	if err != nil {
		return nil, err
	}
	return d.talentsView(p, spend), nil
}

// loadTalents reads what a lord has bought.
func (d Deps) loadTalents(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (talents.Spend, error) {
	rows, err := q.ListTalents(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("talents: %w", err)
	}
	spend := make(talents.Spend, len(rows))
	for _, r := range rows {
		spend[r.TalentID] = int(r.Ranks)
	}
	return spend, nil
}

func (d Deps) talentsView(p sqlcdb.AppPlayer, spend talents.Spend) *TalentsView {
	cfg := d.Config.Talents
	at := d.Config.SectionLevel(cfg.Section)
	level, legacy := int64(p.Level), int64(p.Legacy)

	v := &TalentsView{
		Unlocked: int(p.Level) >= at, UnlockLevel: at,
		Points:     talents.Points(d.Config, level, legacy),
		Spent:      talents.Bought(spend),
		Left:       talents.Left(d.Config, spend, level, legacy),
		RespecCost: talents.RespecCost(d.Config, int64(p.TalentRespecs)),
		Respecs:    int(p.TalentRespecs),
		Branches:   []TalentBranchView{},
	}
	v.NextPointAt = d.nextPointLevel(level)

	for bi := range cfg.Branches {
		br := &cfg.Branches[bi]
		bv := TalentBranchView{
			ID: br.ID, Name: br.Name, Blurb: br.Blurb,
			Spent:   talents.InBranch(d.Config, spend, br.ID),
			Talents: []TalentView{},
		}
		for ti := range br.Talents {
			x := &br.Talents[ti]
			bought := spend[x.ID]
			tv := TalentView{
				ID: x.ID, Name: x.Name, Blurb: x.Blurb, Tier: x.Tier,
				Bucket: x.Bucket, PerRank: x.PerRank, Ranks: x.Ranks,
				Bought: bought, Now: x.PerRank * int64(bought),
				Needs: cfg.TierOpensAt(x.Tier),
				Open:  talents.Open(d.Config, spend, x.ID),
			}
			tv.CanBuy = v.Unlocked && talents.CanBuy(d.Config, spend, level, legacy, x.ID) == nil
			bv.Talents = append(bv.Talents, tv)
		}
		v.Branches = append(v.Branches, bv)
	}
	return v
}

// nextPointLevel is the level that hands the next point over, or 0 past the cap.
//
// The client prints it under the counter ("the next at 24"), so it is worked
// out here: a level a screen computed itself is a level that disagrees the day
// the balance moves.
func (d Deps) nextPointLevel(level int64) int64 {
	c := d.Config.Talents
	if c.LevelsPerPoint <= 0 {
		return 0
	}
	next := c.FirstLevel
	if level >= c.FirstLevel {
		n := (level-c.FirstLevel)/c.LevelsPerPoint + 1
		next = c.FirstLevel + n*c.LevelsPerPoint
	}
	if next > int64(d.Config.Progression.LevelCap) {
		return 0
	}
	return next
}

// TalentsResult is what a tap on the tree gives back: the tree as it now
// stands, and the snapshot, because a rank can lift the pool's own ceiling.
type TalentsResult struct {
	Talents  *TalentsView `json:"talents"`
	Snapshot *Snapshot    `json:"snapshot"`
}

// BuyTalent spends one point.
//
// Sequenced, like every other tap that changes what the lord is worth: a rank
// can raise the energy ceiling and the soldiers' attack, and the client's
// queued collects are counting on the order.
func (d Deps) BuyTalent(ctx context.Context, playerID uuid.UUID, talentID string, wantSeq int64) (*TalentsResult, error) {
	var out *TalentsView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		if int(p.Level) < d.Config.SectionLevel(d.Config.Talents.Section) {
			return ErrTalentsLocked
		}
		spend, err := d.loadTalents(ctx, q, playerID)
		if err != nil {
			return err
		}
		if err := talents.CanBuy(d.Config, spend, int64(p.Level), int64(p.Legacy), talentID); err != nil {
			switch {
			case errors.Is(err, talents.ErrUnknown):
				return ErrTalentUnknown
			case errors.Is(err, talents.ErrMaxRanks):
				return ErrTalentMaxed
			case errors.Is(err, talents.ErrNoPoints):
				return ErrTalentPoints
			case errors.Is(err, talents.ErrShut):
				return fmt.Errorf("%w: %s", ErrTalentShut, err)
			}
			return err
		}
		row, err := q.BuyTalentRank(ctx, sqlcdb.BuyTalentRankParams{
			PlayerID: playerID, TalentID: talentID,
		})
		if err != nil {
			return fmt.Errorf("buy talent: %w", err)
		}
		spend[talentID] = int(row.Ranks)
		after, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: p.ID, ActionSeq: wantSeq})
		if err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		out = d.talentsView(after, spend)
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	return &TalentsResult{Talents: out, Snapshot: snap}, err
}

// RespecTalents takes every rank back for gold.
func (d Deps) RespecTalents(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*TalentsResult, error) {
	var out *TalentsView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		spend, err := d.loadTalents(ctx, q, playerID)
		if err != nil {
			return err
		}
		if talents.Bought(spend) == 0 {
			return ErrNoTalents
		}
		cost := talents.RespecCost(d.Config, int64(p.TalentRespecs))
		if p.Gold < cost {
			return ErrNotEnoughGold
		}
		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: cost, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("respec gold: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: "talent_respec", RefID: strPtr(fmt.Sprint(p.TalentRespecs + 1)),
		}); err != nil {
			return fmt.Errorf("gold ledger: %w", err)
		}
		if err := q.ClearTalents(ctx, playerID); err != nil {
			return fmt.Errorf("clear talents: %w", err)
		}
		n, err := q.BumpTalentRespecs(ctx, playerID)
		if err != nil {
			return fmt.Errorf("count respec: %w", err)
		}
		after.TalentRespecs = n
		out = d.talentsView(after, talents.Spend{})
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	return &TalentsResult{Talents: out, Snapshot: snap}, err
}
