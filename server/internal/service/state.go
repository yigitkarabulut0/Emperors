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
	Player PlayerView `json:"player"`
	Energy EnergyView `json:"energy"`
	// The estates' income, waiting to be carried in (storehouse.go).
	Storehouse StorehouseView `json:"storehouse"`
	// What is running for everyone, and what it is worth to this lord (live.go).
	Live LiveView `json:"live"`
	// The daily loop: the Tax Cart at the gate (cart.go), the Golden Hour
	// (frenzy.go) and the steward's guide (guide.go).
	Cart     CartSnap      `json:"cart"`
	Frenzy   FrenzyView    `json:"frenzy"`
	Guide    GuideView     `json:"guide"`
	Sections []SectionView `json:"sections"`
	Jobs     []JobView     `json:"jobs"`
	Prices   PricesView    `json:"prices"`
	ServerAt time.Time     `json:"server_at"`
	Config   ConfigVersion `json:"config"`
}

// PricesView is what a screen quotes before the player commits. Sent resolved,
// from the live balance, so the number on a button can never disagree with
// the number the server charges.
type PricesView struct {
	RenameDiamonds int64 `json:"rename_diamonds"`
	// What one stat point buys, so the allocation panel can say it before the
	// point is spent -- and spent points cannot be moved.
	StatGains StatGains `json:"stat_gains"`
}

// StatGains is one stat point's worth, per stat.
type StatGains struct {
	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	Energy  int64 `json:"energy"`
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
	// Always 0 now. Estate income fills the storehouse (Snapshot.Storehouse)
	// rather than the purse, and a build from before the storehouse ticks its
	// gold counter up by this rate: sent as 0, its purse sits still, as it is.
	TaxMilliPerHour int64 `json:"tax_milli_per_hour"`
	// Seconds of protection left, 0 for none. The pills count it down; a
	// shield was bought and then never seen again.
	ShieldSeconds int64 `json:"shield_seconds"`
	// Royal Favour: the seal every lord sees (vip_seal) and the level only the
	// lord sees. Crown Patronage's time left, 0 for none.
	VIPSeal       bool  `json:"vip_seal"`
	VIPLevel      int   `json:"vip_level"`
	PatronSeconds int64 `json:"patron_seconds"`
	Steward       bool  `json:"steward"`
	// Diamonds a refund took back that had been spent; paid first out of the
	// next diamonds earned.
	DiamondDebt int64 `json:"diamond_debt"`
	// What the lord wears, resolved for drawing: under the same key as every
	// other lord's look (Look.Worn), so one reader draws them all.
	Worn Worn `json:"worn"`
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
	ID             string      `json:"id"`
	Name           string      `json:"name"`
	Order          int         `json:"order"`
	EnergyCost     int64       `json:"energy_cost"`
	GoldPayout     int64       `json:"gold_payout"`
	XPPayout       int64       `json:"xp_payout"`
	Collects       int64       `json:"collects"`
	MasteryBonusBP int64       `json:"mastery_bonus_bp"`
	NextMilestone  int64       `json:"next_milestone,omitempty"`
	UnlockLevel    int         `json:"unlock_level"`
	Unlocked       bool        `json:"unlocked"`
	Mastery        MasteryView `json:"mastery"`
}

// MasteryView is the stretch of the mastery ladder a Collect row shows: the
// threshold last reached (whose bonus is in force), the next one, and the one
// after it. Resolved here so the client labels three markers and fills the
// track between the first two without holding the ladder or walking it -- a
// second copy of "which threshold counts" is how a row would come to show a
// bonus the purse does not pay. A zero threshold means none: nothing reached
// yet (Reached), or the ladder is finished (Next, After).
type MasteryView struct {
	Reached   int64 `json:"reached"`
	ReachedBP int64 `json:"reached_bp"`
	Next      int64 `json:"next"`
	NextBP    int64 `json:"next_bp"`
	After     int64 `json:"after"`
	AfterBP   int64 `json:"after_bp"`
}

// masteryView resolves a row's stretch of the ladder at this collect count.
func masteryView(cfg *gameconfig.Bundle, collects int64) MasteryView {
	var v MasteryView
	ms := cfg.Jobs.Milestones // ascending, see Bundle.build
	i := 0
	for i < len(ms) && collects >= ms[i].Collects {
		i++
	}
	if i > 0 {
		v.Reached, v.ReachedBP = ms[i-1].Collects, ms[i-1].BonusBP
	}
	if i < len(ms) {
		v.Next, v.NextBP = ms[i].Collects, ms[i].BonusBP
	}
	if i+1 < len(ms) {
		v.After, v.AfterBP = ms[i+1].Collects, ms[i+1].BonusBP
	}
	return v
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

	// Keep the storehouse's cached rate and capacity honest: every mutating
	// endpoint ends here, with everything they depend on loaded, and a change
	// is settled at the old pair first (refreshStorehouse). A failure costs the
	// snapshot nothing: the old pair is still true up to now, and the next
	// request stores the new one.
	if err := d.refreshStorehouse(ctx, q, &p, eff, now); err != nil && d.Log != nil {
		d.Log.Warn("storehouse refresh", "player", p.ID, "err", err)
	}
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

	pv := playerView(d.Config, p, now)
	pv.Steward = d.stewardActive(p, now)
	if own, err := d.owned(ctx, q, p.ID, now); err == nil {
		pv.Worn = d.wornOf(p, own)
	}
	held, err := tokenCounts(ctx, q, p.ID)
	if err != nil {
		return nil, err
	}

	return &Snapshot{
		Player:     pv,
		Energy:     energyView(settled, maxEnergy, period),
		Storehouse: d.storehouseView(p, eff, now),
		Live:       d.liveView(ctx, q, p, eff, now),
		Cart:       d.cartSnap(p, held["cart"], now),
		Frenzy:     d.frenzyView(p, maxEnergy, now),
		Guide:      d.guideView(ctx, q, p),
		Sections:   sectionViews(d.Config, int(p.Level), p.KingdomID != nil),
		Jobs:       jobViews(d.Config, p, collects, eff.Bonuses),
		Prices: PricesView{
			RenameDiamonds: d.Config.Progression.Store.RenameDiamonds,
			StatGains: StatGains{
				Attack:  d.Config.Soldiers.Player.PerStatPoint,
				Defense: d.Config.Soldiers.Player.PerStatPoint,
				Energy:  d.Config.Progression.Energy.PerStatPoint,
			},
		},
		ServerAt: now.UTC(),
		Config:   ConfigVersion{Version: d.Config.Version},
	}, nil
}

// settleEnergy materialises energy up to now and returns the derived limits.
func settleEnergy(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, eff estates.Effects, now time.Time) (economy.EnergyState, int64, int64) {
	maxEnergy := economy.MaxEnergy(cfg, int64(p.Level), int64(p.StatEnergy), eff.MaxEnergyFlat)
	period := economy.RegenPeriodMillis(cfg, eff.Bonuses)
	state := economy.Settle(
		economy.EnergyState{Milli: p.EnergyMilli, UpdatedAt: p.EnergyUpdatedAt},
		maxEnergy, period, now,
	)
	return state, maxEnergy, period
}

// sectionViews says which tabs are open. The client reads Unlocked rather than
// comparing levels itself.
//
// A lord who belongs to a kingdom always has its tab: a Legacy puts them back
// at level 1, far under the level that first opened it, and locking a king out
// of his own kingdom for twenty levels is not a rule anyone would choose.
func sectionViews(cfg *gameconfig.Bundle, level int, inKingdom bool) []SectionView {
	out := make([]SectionView, 0, len(cfg.Progression.Sections))
	for _, g := range cfg.Progression.Sections {
		open := level >= g.Level
		if g.ID == kingdomSection && inKingdom {
			open = true
		}
		out = append(out, SectionView{
			ID: g.ID, UnlockLevel: g.Level, Unlocked: open,
		})
	}
	return out
}

// kingdomSection is the navigation section that opens the Kingdom tab.
const kingdomSection = "house"

func playerView(cfg *gameconfig.Bundle, p sqlcdb.AppPlayer, now time.Time) PlayerView {
	var shield int64
	if p.ShieldUntil != nil && p.ShieldUntil.After(now) {
		shield = int64(p.ShieldUntil.Sub(now) / time.Second)
	}
	return PlayerView{
		ShieldSeconds:     shield,
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
		TaxMilliPerHour:   0,
		VIPSeal:           p.VipPoints > 0 && cfg.VIPLevel(p.VipPoints) > 0,
		VIPLevel:          cfg.VIPLevel(p.VipPoints),
		PatronSeconds:     patronSeconds(p, now),
		DiamondDebt:       p.DiamondDebt,
	}
}

func patronSeconds(p sqlcdb.AppPlayer, now time.Time) int64 {
	if !patronActive(p, now) {
		return 0
	}
	return int64(p.PatronUntil.Sub(now) / time.Second)
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
			EnergyCost: j.EnergyCost,
			GoldPayout: res.Gold,
			// The bucket, applied here too.
			//
			// economy.Collect returns the job's RAW experience, because AwardXP is
			// what applies the experience bucket when the collect actually lands.
			// That is correct for the award and wrong for the list: during a
			// double-experience event every row advertised the base number and
			// then paid twice it, so the one screen a player reads constantly
			// disagreed with what they were given.
			XPPayout:       economy.ApplyBucket(res.XP, bonuses, economy.BucketXPGain),
			Collects:       done,
			MasteryBonusBP: cfg.MilestoneBonusBP(done),
			Mastery:        masteryView(cfg, done),
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
