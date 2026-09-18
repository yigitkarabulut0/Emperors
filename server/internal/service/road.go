package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/game/road"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The Victory Road (retention.road): fifteen milestones on the way to the level
// cap, each claimed once, any time after it is reached -- a lord already past
// one when the road opened claims it the same.

// ErrRoadEmpty is a claim with nothing reached and unclaimed.
var ErrRoadEmpty = errors.New("there is nothing on the road to claim")

// RoadMilestone is one milestone as the lord stands to it.
type RoadMilestone struct {
	Index   int            `json:"index"`
	Level   int            `json:"level"`
	Reached bool           `json:"reached"`
	Claimed bool           `json:"claimed"`
	Crown   bool           `json:"crown"`
	Lines   []rewards.Line `json:"lines"`
}

// RoadView is the road.
type RoadView struct {
	Level         int             `json:"level"`
	Claimable     int             `json:"claimable"`
	DiamondsTotal int64           `json:"diamonds_total"`
	Milestones    []RoadMilestone `json:"milestones"`
}

// RoadClaim is what a claim paid.
type RoadClaim struct {
	Lines    []rewards.Line `json:"lines"`
	Road     *RoadView      `json:"road"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// roadClaimable is how many milestones wait for the lord: the rail's badge.
func (d Deps) roadClaimable(p sqlcdb.AppPlayer) int {
	return len(road.Claimable(road.Build(d.Config.Retention.Road.Milestones, int(p.Level), uint32(p.RoadClaimed))))
}

// GetRoad reports the road.
func (d Deps) GetRoad(ctx context.Context, playerID uuid.UUID) (*RoadView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("road: %w", err)
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	bonuses := rewards.PermanentOnly(eff.Bonuses)
	ms := d.Config.Retention.Road.Milestones
	nodes := road.Build(ms, int(p.Level), uint32(p.RoadClaimed))
	v := &RoadView{Level: int(p.Level), Claimable: len(road.Claimable(nodes)), Milestones: []RoadMilestone{}}
	for i, n := range nodes {
		g := ms[i].Grant
		v.DiamondsTotal += g.Diamonds
		v.Milestones = append(v.Milestones, RoadMilestone{
			Index: n.Index, Level: n.Level, Reached: n.Reached, Claimed: n.Claimed, Crown: n.Crown,
			Lines: rewards.Lines(d.Config, g, rewards.Resolve(d.Config, g, int(p.Level), bonuses)),
		})
	}
	return v, nil
}

// ClaimRoad claims one reached milestone, or with index nil every one waiting.
// All or nothing: a milestone whose gear has no room fails the claim, and the
// rest wait with it.
func (d Deps) ClaimRoad(ctx context.Context, playerID uuid.UUID, index *int) (*RoadClaim, error) {
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
		ms := d.Config.Retention.Road.Milestones
		nodes := road.Build(ms, int(p.Level), uint32(p.RoadClaimed))
		want := road.Claimable(nodes)
		if index != nil {
			i := *index
			if i < 0 || i >= len(nodes) {
				return ErrNotFound
			}
			switch {
			case nodes[i].Claimed:
				return ErrAlreadyClaimed
			case !nodes[i].Reached:
				return ErrRoadEmpty
			}
			want = []int{i}
		}
		if len(want) == 0 {
			return ErrRoadEmpty
		}
		after, err := q.ClaimRoad(ctx, sqlcdb.ClaimRoadParams{ID: p.ID, Mask: int32(road.Mask(want))})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim the road: %w", err)
		}
		p = after
		for _, i := range want {
			g, err := d.grantBundle(ctx, q, &p, ms[i].Grant, GrantSource{
				Diamonds: ledger.Road, Gold: "road", Ref: fmt.Sprintf("road:%d", ms[i].Level), ItemFrom: "reward",
			})
			if err != nil {
				return err
			}
			lines = append(lines, g.Lines...)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	view, err := d.GetRoad(ctx, playerID)
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return &RoadClaim{Lines: lines, Road: view, Snapshot: snap}, nil
}
