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
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/hunt"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// THE EXPEDITIONS -- the Army tab's HUNT (hunt.json).
//
// A soldier is sent out for an hour, two, four or eight, and comes back with
// what they found. It is the only income in the game that costs no energy at
// all, so what it costs instead is the SOLDIER: away, they do not fight in
// their lord's own battles and cannot be rerolled, dismissed or re-geared.
//
// The haul is rolled AT DISPATCH and frozen in the row. Rolling it on the way
// home would make it a reward to wait on a clock for, and a lord who was shown
// a range before the tap is owed a number the tap decided. A recall pays
// nothing at all: a reward that survives a recall is a reward taken by
// cancelling.

var (
	ErrHuntLocked = errors.New("expeditions open later")
	ErrHuntSlots  = errors.New("you have as many soldiers out as you may")
	ErrHuntField  = errors.New("no such field")
	ErrHuntAway   = errors.New("that soldier is already away")
	ErrHuntSoon   = errors.New("that soldier is still on the road")
	ErrHuntGone   = errors.New("that expedition has been settled")
)

// HuntView is the sub-tab: who is out, who may go, and where.
type HuntView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`
	// How many may be out at once, how many are, and the level that opens the
	// next one (0 when there is no next).
	Slots      int   `json:"slots"`
	Used       int   `json:"used"`
	NextSlotAt int64 `json:"next_slot_at"`

	// The soldier the ranges are quoted for: the one the client asked about, or
	// none, in which case the ranges are the plainest soldier's.
	SoldierID   string `json:"soldier_id,omitempty"`
	SoldierTier string `json:"soldier_tier,omitempty"`

	Fields []HuntFieldView `json:"fields"`
	Away   []HuntAwayView  `json:"away"`
}

// HuntFieldView is one place to send a soldier, with what it promises.
type HuntFieldView struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	Hours int64  `json:"hours"`
	// The range the card shows before the tap, at this soldier's rank and
	// already RESOLVED for this lord: the gold and the experience they would
	// actually be handed, not the wages the balance is written in. A screen
	// that printed wages would be printing a unit only the server understands.
	GoldLow  int64 `json:"gold_low"`
	GoldHigh int64 `json:"gold_high"`
	XPLow    int64 `json:"xp_low"`
	XPHigh   int64 `json:"xp_high"`
	// The chance of a piece of gear, and its rank.
	ItemChanceBP int64  `json:"item_chance_bp"`
	ItemTier     string `json:"item_tier,omitempty"`
}

// HuntAwayView is one soldier on the road.
type HuntAwayView struct {
	ID        string `json:"id"`
	SoldierID string `json:"soldier_id"`
	Soldier   string `json:"soldier"`
	Tier      string `json:"tier"`
	FieldID   string `json:"field_id"`
	Field     string `json:"field"`
	EndsIn    int64  `json:"ends_in"`
	Back      bool   `json:"back"`
	// What they are carrying, shown only once they are standing at the gate:
	// the wait is the point, and a card that showed the haul all night would
	// take it away.
	Lines []string `json:"lines,omitempty"`
}

// soldierAway is the ribbon the Army tab's own card wears.
func (d Deps) soldierAway(r sqlcdb.AppExpedition, now time.Time) *SoldierAway {
	v := &SoldierAway{ID: r.ID.String(), FieldID: r.FieldID}
	if f := d.Config.Hunt.Field(r.FieldID); f != nil {
		v.Field = f.Name
	}
	if r.EndsAt.After(now) {
		v.EndsIn = int64(r.EndsAt.Sub(now).Seconds()) + 1
	} else {
		v.Back = true
	}
	return v
}

// GetHunt paints the sub-tab. A soldier may be named, and then every range is
// quoted at that soldier's rank -- the client works nothing out.
func (d Deps) GetHunt(ctx context.Context, playerID uuid.UUID, soldierID *uuid.UUID) (*HuntView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("hunt: %w", err)
	}
	cfg := d.Config.Hunt
	at := d.Config.SectionLevel(cfg.Section)
	now := d.Now()

	v := &HuntView{
		Unlocked: int(p.Level) >= at, UnlockLevel: at,
		Slots:  cfg.SlotsAt(int64(p.Level)),
		Fields: []HuntFieldView{}, Away: []HuntAwayView{},
	}
	v.NextSlotAt = nextSlotLevel(d.Config, int64(p.Level))

	// Whose rank the ranges are quoted at. A soldier nobody named, or one who
	// is already away, quotes the plainest rank rather than refusing: the card
	// is a promise about the FIELD, and it must still read.
	tier := d.Config.TierIDsAscending()[0]
	soldiers, err := q.ListSoldiers(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("soldiers: %w", err)
	}
	byID := make(map[uuid.UUID]sqlcdb.AppSoldier, len(soldiers))
	for _, s := range soldiers {
		byID[s.ID] = s
	}
	if soldierID != nil {
		if s, ok := byID[*soldierID]; ok {
			tier, v.SoldierID, v.SoldierTier = s.Tier, s.ID.String(), s.Tier
		}
	}

	// What a haul is worth to THIS lord: wages are energy, and energy is worth
	// what their best job pays for it, through the same buckets a reward is
	// paid through (rewards.Resolve, the permanent lane only).
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	worth := func(h hunt.Haul) (int64, int64) {
		r := rewards.Resolve(d.Config, h.Bundle(), int(p.Level), eff.Bonuses)
		return r.Gold, r.XP
	}
	for i := range cfg.Fields {
		f := &cfg.Fields[i]
		low, high := hunt.Range(d.Config, f, tier)
		lg, lx := worth(low)
		hg, hx := worth(high)
		v.Fields = append(v.Fields, HuntFieldView{
			ID: f.ID, Name: f.Name, Blurb: f.Blurb, Hours: f.Hours,
			GoldLow: lg, GoldHigh: hg, XPLow: lx, XPHigh: hx,
			ItemChanceBP: f.ItemChanceBP, ItemTier: f.ItemTier,
		})
	}

	rows, err := q.ListExpeditions(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("expeditions: %w", err)
	}
	v.Used = len(rows)
	for _, r := range rows {
		a := HuntAwayView{
			ID: r.ID.String(), SoldierID: r.SoldierID.String(), FieldID: r.FieldID,
		}
		if s, ok := byID[r.SoldierID]; ok {
			a.Soldier, a.Tier = d.soldierTypeName(s.TypeID), s.Tier
		}
		if f := d.Config.Hunt.Field(r.FieldID); f != nil {
			a.Field = f.Name
		}
		if r.EndsAt.After(now) {
			a.EndsIn = int64(r.EndsAt.Sub(now).Seconds()) + 1
		} else {
			a.Back = true
			// What they are carrying, in the words every other reward is said
			// in, and only once they are at the gate: a card that showed the
			// haul all night would take the wait away.
			a.Lines = d.rewardLines(haulOf(r).Bundle(), int(p.Level))
		}
		v.Away = append(v.Away, a)
	}
	return v, nil
}

// nextSlotLevel is the level that opens one more expedition, or 0 at the last
// rung. Worked out here, because a level a screen computed itself is a level
// that disagrees the day the balance moves.
func nextSlotLevel(cfg *gameconfig.Bundle, level int64) int64 {
	have := cfg.Hunt.SlotsAt(level)
	for _, s := range cfg.Hunt.Slots {
		if s.Slots > have {
			return s.Level
		}
	}
	return 0
}

// haulOf reads the frozen haul off a row.
func haulOf(r sqlcdb.AppExpedition) hunt.Haul {
	h := hunt.Haul{GoldWages: r.GoldWages, XPWages: r.XpWages}
	if r.ItemTier != nil {
		h.ItemTier = *r.ItemTier
	}
	return h
}

// mustBeHome refuses an action on a soldier who is out on the road.
//
// A soldier away is away for every purpose but defending their lord's walls:
// they cannot be rerolled into somebody else, let go, or handed a different
// sword. One question, asked in three places, so the three cannot drift.
func (d Deps) mustBeHome(ctx context.Context, q *sqlcdb.Queries, soldierID uuid.UUID) error {
	away, err := q.SoldierIsAway(ctx, soldierID)
	if err != nil {
		return fmt.Errorf("soldier away: %w", err)
	}
	if away {
		return ErrHuntAway
	}
	return nil
}

// SendHunt sends one soldier to one field.
//
// Not sequenced: nothing in the purse moves. What it changes is who is standing
// in the yard, which the Army tab reads for itself.
func (d Deps) SendHunt(ctx context.Context, playerID uuid.UUID, soldierID uuid.UUID,
	fieldID string) (*HuntView, error) {

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		cfg := d.Config.Hunt
		if int(p.Level) < d.Config.SectionLevel(cfg.Section) {
			return ErrHuntLocked
		}
		f := cfg.Field(fieldID)
		if f == nil {
			return ErrHuntField
		}
		s, err := q.GetSoldier(ctx, sqlcdb.GetSoldierParams{ID: soldierID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("soldier: %w", err)
		}
		out, err := q.CountExpeditions(ctx, playerID)
		if err != nil {
			return fmt.Errorf("count expeditions: %w", err)
		}
		if int(out) >= cfg.SlotsAt(int64(p.Level)) {
			return ErrHuntSlots
		}

		now := d.Now()
		// Rolled HERE, at the tap, and frozen in the row.
		rng := game.SeedForString(d.ShopSecret, "hunt:"+soldierID.String(),
			uint64(now.UnixNano()), uint64(len(fieldID)))
		h := hunt.Roll(d.Config, rng, f, s.Tier)

		var itemTier *string
		if h.ItemTier != "" {
			t := h.ItemTier
			itemTier = &t
		}
		if _, err := q.SendExpedition(ctx, sqlcdb.SendExpeditionParams{
			PlayerID: playerID, SoldierID: soldierID, FieldID: f.ID,
			Now: now, EndsAt: hunt.Ends(f, now),
			GoldWages: h.GoldWages, XpWages: h.XPWages, ItemTier: itemTier,
			ConfigVersion: int32(d.Config.Version),
		}); err != nil {
			// The one unique index on the table says a soldier is in one place.
			if db.IsUniqueViolation(err, "expeditions_one_per_soldier_idx") {
				return ErrHuntAway
			}
			return fmt.Errorf("send expedition: %w", err)
		}
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.HuntsSent: 1})
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetHunt(ctx, playerID, &soldierID)
}

// HuntReturn is what a soldier brought home.
type HuntReturn struct {
	Granted  Granted   `json:"granted"`
	Hunt     *HuntView `json:"hunt"`
	Snapshot *Snapshot `json:"snapshot"`
}

// CollectHunt lets a soldier back in with what they found.
//
// Sequenced: it pays wages, and the client's queued collects are counting on
// the order. A full bag refuses the whole thing -- the soldier waits at the
// gate rather than the haul being half-paid.
func (d Deps) CollectHunt(ctx context.Context, playerID, id uuid.UUID, wantSeq int64) (*HuntReturn, error) {
	res := &HuntReturn{}
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
		row, err := q.LockExpedition(ctx, sqlcdb.LockExpeditionParams{ID: id, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrHuntGone
			}
			return fmt.Errorf("lock expedition: %w", err)
		}
		now := d.Now()
		if row.EndsAt.After(now) {
			return ErrHuntSoon
		}
		g, err := d.grantBundle(ctx, q, &p, haulOf(row).Bundle(), GrantSource{
			Diamonds: ledger.Reward, Gold: "hunt", Ref: "hunt:" + row.ID.String(),
			ItemFrom: "expedition",
		})
		if err != nil {
			return err
		}
		if _, err := q.SettleExpedition(ctx, sqlcdb.SettleExpeditionParams{
			ID: row.ID, Now: &now, Outcome: strPtr("home"),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrHuntGone
			}
			return fmt.Errorf("settle expedition: %w", err)
		}
		if _, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{
			ID: playerID, ActionSeq: wantSeq,
		}); err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.HuntsReturned: 1})
		res.Granted = g
		return nil
	})
	if err != nil {
		return nil, err
	}
	if res.Hunt, err = d.GetHunt(ctx, playerID, nil); err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}

// RecallHunt calls a soldier back early. They bring nothing.
func (d Deps) RecallHunt(ctx context.Context, playerID, id uuid.UUID) (*HuntView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		if _, err := q.LockExpedition(ctx, sqlcdb.LockExpeditionParams{
			ID: id, PlayerID: playerID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrHuntGone
			}
			return fmt.Errorf("lock expedition: %w", err)
		}
		now := d.Now()
		if _, err := q.SettleExpedition(ctx, sqlcdb.SettleExpeditionParams{
			ID: id, Now: &now, Outcome: strPtr("recalled"),
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrHuntGone
			}
			return fmt.Errorf("settle expedition: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetHunt(ctx, playerID, nil)
}
