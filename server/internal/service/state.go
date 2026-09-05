package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Snapshot is everything the client needs to render, in one response.
//
// One endpoint rather than a dozen: a mobile client on a cold start would
// otherwise pay a TLS handshake per resource, and the pieces must be mutually
// consistent — energy and gold read a second apart can disagree.
type Snapshot struct {
	Player   PlayerView    `json:"player"`
	Energy   EnergyView    `json:"energy"`
	Sections []SectionView `json:"sections"`
	Jobs     []JobView     `json:"jobs"`
	ServerAt time.Time     `json:"server_at"`
	Config   ConfigVersion `json:"config"`
}

// SectionView is one navigation entry: whether the player has reached it, and
// the level that opens it if not. Sent with state so the client never has to
// hold its own copy of the progression rules.
type SectionView struct {
	ID          string `json:"id"`
	UnlockLevel int    `json:"unlock_level"`
	Unlocked    bool   `json:"unlocked"`
}

type PlayerView struct {
	ID                string `json:"id"`
	Username          string `json:"username"`
	Avatar            string `json:"avatar"`
	Level             int    `json:"level"`
	XP                int64  `json:"xp"`
	XPToNext          int64  `json:"xp_to_next"`
	Gold              string `json:"gold"` // string: can exceed 2^53 and JS would round it
	Treasury          string `json:"treasury"`
	Diamonds          int64  `json:"diamonds"`
	StatEnergy        int    `json:"stat_energy"`
	StatAttack        int    `json:"stat_attack"`
	StatDefense       int    `json:"stat_defense"`
	StatPointsUnspent int    `json:"stat_points_unspent"`
	ActionSeq         int64  `json:"action_seq"`
}

// EnergyView carries the rate as well as the value, so the client can animate a
// filling bar between polls without asking the server again.
type EnergyView struct {
	Current       int64 `json:"current"`
	Max           int64 `json:"max"`
	RegenPeriodMS int64 `json:"regen_period_ms"`
	SecondsToFull int64 `json:"seconds_to_full"`
}

// JobView is one Collect row. Payouts are RESOLVED — already multiplied by every
// bonus and already rounded — so the client's optimistic prediction is a table
// lookup rather than a re-implementation of the economy that could drift.
type JobView struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Order          int    `json:"order"`
	EnergyCost     int64  `json:"energy_cost"`
	GoldPayout     int64  `json:"gold_payout"`
	XPPayout       int64  `json:"xp_payout"`
	Collects       int64  `json:"collects"`
	MasteryBonusBP int64  `json:"mastery_bonus_bp"`
	NextMilestone  int64  `json:"next_milestone,omitempty"`
	UnlockLevel    int    `json:"unlock_level"`
	Unlocked       bool   `json:"unlocked"`
}

type ConfigVersion struct {
	Version int `json:"version"`
}

// GetState returns a consistent snapshot, settling time-based resources first so
// the client never sees stale energy.
func (d Deps) GetState(ctx context.Context, playerID uuid.UUID) (*Snapshot, error) {
	q := sqlcdb.New(d.Pool)

	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}

	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	now := d.Now()
	settled, maxEnergy, period := settleEnergy(d.Config, p, eff, now)

	// Persist the settled value opportunistically. If this fails the request
	// still succeeds: energy is derived from (value, anchor), so the next write
	// recomputes it correctly from the old anchor. Losing the write costs
	// nothing; failing the request over it would cost a session.
	if settled.Milli != p.EnergyMilli || !settled.UpdatedAt.Equal(p.EnergyUpdatedAt) {
		_ = q.SettleEnergy(ctx, sqlcdb.SettleEnergyParams{
			ID: p.ID, EnergyMilli: settled.Milli, EnergyUpdatedAt: settled.UpdatedAt,
		})
	}

	progress, err := q.ListJobProgress(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("load job progress: %w", err)
	}
	collects := make(map[string]int64, len(progress))
	for _, row := range progress {
		collects[row.JobID] = row.Collects
	}

	return &Snapshot{
		Player:   playerView(d.Config, p),
		Energy:   energyView(settled, maxEnergy, period),
		Sections: sectionViews(d.Config, int(p.Level)),
		Jobs:     jobViews(d.Config, p, collects, eff.Bonuses),
		ServerAt: now.UTC(),
		Config:   ConfigVersion{Version: d.Config.Version},
	}, nil
}

// settleEnergy materialises energy up to now and returns the derived limits.
func settleEnergy(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) (economy.EnergyState, int64, int64) {
	maxEnergy := economy.MaxEnergy(cfg, int64(p.StatEnergy), eff.MaxEnergyFlat)
	period := economy.RegenPeriodMillis(cfg, eff.Bonuses)
	state := economy.Settle(
		economy.EnergyState{Milli: p.EnergyMilli, UpdatedAt: p.EnergyUpdatedAt},
		maxEnergy, period, now,
	)
	return state, maxEnergy, period
}

func sectionViews(cfg *gameconfig.Bundle, level int) []SectionView {
	out := make([]SectionView, 0, len(cfg.Progression.Sections))
	for _, g := range cfg.Progression.Sections {
		out = append(out, SectionView{
			ID: g.ID, UnlockLevel: g.Level, Unlocked: level >= g.Level,
		})
	}
	return out
}

func playerView(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer) PlayerView {
	return PlayerView{
		ID:                p.ID.String(),
		Username:          p.DisplayName,
		Avatar:            p.Avatar,
		Level:             int(p.Level),
		XP:                p.Xp,
		XPToNext:          cfg.XPToNext(int(p.Level)),
		Gold:              itoa(p.Gold),
		Treasury:          itoa(p.TreasuryGold),
		Diamonds:          p.Diamonds,
		StatEnergy:        int(p.StatEnergy),
		StatAttack:        int(p.StatAttack),
		StatDefense:       int(p.StatDefense),
		StatPointsUnspent: int(p.StatPointsUnspent),
		ActionSeq:         p.ActionSeq,
	}
}

func energyView(s economy.EnergyState, maxEnergy, period int64) EnergyView {
	return EnergyView{
		Current:       economy.Whole(s),
		Max:           maxEnergy,
		RegenPeriodMS: period,
		SecondsToFull: economy.SecondsUntilFull(s, maxEnergy, period),
	}
}

func jobViews(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, collects map[string]int64, bonuses economy.Bonuses) []JobView {
	out := make([]JobView, 0, len(cfg.Jobs.Jobs))
	for i := range cfg.Jobs.Jobs {
		j := &cfg.Jobs.Jobs[i]
		done := collects[j.ID]
		res := economy.Collect(cfg, j, done, bonuses)

		v := JobView{
			ID: j.ID, Name: j.Name, Order: j.Order,
			EnergyCost:     j.EnergyCost,
			GoldPayout:     res.Gold,
			XPPayout:       res.XP,
			Collects:       done,
			MasteryBonusBP: cfg.MilestoneBonusBP(done),
			UnlockLevel:    j.UnlockLevel,
			Unlocked:       j.UnlockLevel <= int(p.Level),
		}
		if m := cfg.NextMilestone(done); m != nil {
			v.NextMilestone = m.Collects
		}
		out = append(out, v)
	}
	return out
}

func itoa(v int64) string { return fmt.Sprintf("%d", v) }
