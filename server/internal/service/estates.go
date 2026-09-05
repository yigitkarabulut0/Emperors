package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
)

var (
	ErrUpgradeMaxed = errors.New("already at maximum level")
	ErrNoTax        = errors.New("nothing to collect yet")
)

// loadEffects reads a player's Family upgrades and Territory holdings and folds
// them into their effects.
//
// One extra query on the hot path, deliberately: caching the derived numbers on
// the player row would mean a balance republish silently leaving every player on
// the old bonuses until something happened to touch them.
func (d Deps) loadEffects(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (estates.Effects, error) {
	ups, err := q.ListUpgrades(ctx, p.ID)
	if err != nil {
		return estates.Effects{}, fmt.Errorf("list upgrades: %w", err)
	}
	holds, err := q.ListHoldings(ctx, p.ID)
	if err != nil {
		return estates.Effects{}, fmt.Errorf("list holdings: %w", err)
	}

	upLevels := make(map[string]int, len(ups))
	for _, u := range ups {
		upLevels[u.UpgradeID] = int(u.Level)
	}
	holdLevels := make(map[string]int, len(holds))
	for _, h := range holds {
		holdLevels[h.HoldingID] = int(h.Level)
	}
	eff := estates.Derive(d.Config, int64(p.Level), upLevels, holdLevels)

	// A kingdom's upgrades apply to every member, so they belong in the same
	// effects the rest of the game reads.
	if p.KingdomID != nil {
		kups, err := q.ListKingdomUpgrades(ctx, *p.KingdomID)
		if err != nil {
			return estates.Effects{}, fmt.Errorf("kingdom upgrades: %w", err)
		}
		kLevels := make(map[string]int, len(kups))
		for _, k := range kups {
			kLevels[k.UpgradeID] = int(k.Level)
		}
		estates.ApplyKingdom(d.Config, &eff, int64(p.Level), kLevels, holdLevels)
	}
	return eff, nil
}

// EstatesView is the Keep tab (upgrades) and the Map tab (holdings).
type EstatesView struct {
	Upgrades []UpgradeView `json:"upgrades"`
	Holdings []HoldingView `json:"holdings"`
	Tax      TaxView       `json:"tax"`
}

type UpgradeView struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Blurb    string `json:"blurb"`
	Bucket   string `json:"bucket"`
	Level    int    `json:"level"`
	MaxLevel int    `json:"max_level"`
	PerLevel int64  `json:"per_level"`
	NextCost int64  `json:"next_cost"`
	Maxed    bool   `json:"maxed"`
	Effect   int64  `json:"effect_now"`
}

type HoldingView struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Level        int    `json:"level"`
	MaxLevel     int    `json:"max_level"`
	UnlockLevel  int    `json:"unlock_level"`
	Unlocked     bool   `json:"unlocked"`
	NextCost     int64  `json:"next_cost"`
	Maxed        bool   `json:"maxed"`
	YieldPerHour int64  `json:"yield_per_hour_milli"`
}

// TaxView is what the Family tab shows about idle income.
//
// Presented per HOUR, never per second: 0.23 gold a second reads as nothing.
type TaxView struct {
	PerHourMilli  int64 `json:"per_hour_milli"`
	Pending       int64 `json:"pending"`
	CapSeconds    int64 `json:"cap_seconds"`
	SecondsToFull int64 `json:"seconds_to_cap"`
}

func (d Deps) GetEstates(ctx context.Context, playerID uuid.UUID) (*EstatesView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}

	ups, err := q.ListUpgrades(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list upgrades: %w", err)
	}
	holds, err := q.ListHoldings(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list holdings: %w", err)
	}
	upLevels := map[string]int{}
	for _, u := range ups {
		upLevels[u.UpgradeID] = int(u.Level)
	}
	holdLevels := map[string]int{}
	for _, h := range holds {
		holdLevels[h.HoldingID] = int(h.Level)
	}
	eff := estates.Derive(d.Config, int64(p.Level), upLevels, holdLevels)

	view := &EstatesView{
		Upgrades: make([]UpgradeView, 0, len(d.Config.Estates.Upgrades)),
		Holdings: make([]HoldingView, 0, len(d.Config.Estates.Holdings)),
	}
	for _, u := range d.Config.Estates.Upgrades {
		lv := upLevels[u.ID]
		cost, ok := u.Cost(lv)
		view.Upgrades = append(view.Upgrades, UpgradeView{
			ID: u.ID, Name: u.Name, Blurb: u.Blurb, Bucket: u.Bucket,
			Level: lv, MaxLevel: u.MaxLevel, PerLevel: u.PerLevel,
			NextCost: cost, Maxed: !ok, Effect: u.PerLevel * int64(lv),
		})
	}
	for _, h := range d.Config.Estates.Holdings {
		lv := holdLevels[h.ID]
		cost, ok := h.Cost(lv)
		view.Holdings = append(view.Holdings, HoldingView{
			ID: h.ID, Name: h.Name, Level: lv, MaxLevel: h.MaxLevel,
			UnlockLevel: h.UnlockLevel, Unlocked: int(p.Level) >= h.UnlockLevel,
			NextCost: cost, Maxed: !ok,
			YieldPerHour: h.TaxMilliPerHourPerLevel * int64(lv),
		})
	}

	now := d.Now()
	settled := estates.SettleTax(
		estates.TaxState{Milli: p.TaxMilliAccrued, UpdatedAt: p.TaxUpdatedAt},
		eff.TaxMilliPerHour, eff.OfflineCapSeconds, now)

	capMilli := eff.TaxMilliPerHour * eff.OfflineCapSeconds / 3600
	var toFull int64
	if eff.TaxMilliPerHour > 0 && settled.Milli < capMilli {
		toFull = (capMilli - settled.Milli) * 3600 / eff.TaxMilliPerHour
	}
	view.Tax = TaxView{
		PerHourMilli:  eff.TaxMilliPerHour,
		Pending:       estates.Whole(settled),
		CapSeconds:    eff.OfflineCapSeconds,
		SecondsToFull: toFull,
	}
	return view, nil
}

// BuyUpgrade advances one Family upgrade by a level.
func (d Deps) BuyUpgrade(ctx context.Context, playerID uuid.UUID, upgradeID string, wantSeq int64) (*EstatesView, error) {
	u := d.Config.Upgrade(upgradeID)
	if u == nil {
		return nil, ErrNotFound
	}
	if err := d.buyLevel(ctx, playerID, wantSeq, func(q *sqlcdb.Queries, level int) (int64, error) {
		cost, ok := u.Cost(level)
		if !ok {
			return 0, ErrUpgradeMaxed
		}
		return cost, nil
	}, func(ctx context.Context, q *sqlcdb.Queries, level int) error {
		_, err := q.BuyUpgradeLevel(ctx, sqlcdb.BuyUpgradeLevelParams{
			PlayerID: playerID, UpgradeID: upgradeID, Level: int32(level),
		})
		return err
	}, func(ctx context.Context, q *sqlcdb.Queries) (int, error) {
		rows, err := q.ListUpgrades(ctx, playerID)
		if err != nil {
			return 0, err
		}
		for _, r := range rows {
			if r.UpgradeID == upgradeID {
				return int(r.Level), nil
			}
		}
		return 0, nil
	}, "family_upgrade:"+upgradeID); err != nil {
		return nil, err
	}
	return d.GetEstates(ctx, playerID)
}

// BuyHolding advances one Territory holding by a level.
func (d Deps) BuyHolding(ctx context.Context, playerID uuid.UUID, holdingID string, wantSeq int64) (*EstatesView, error) {
	h := d.Config.Holding(holdingID)
	if h == nil {
		return nil, ErrNotFound
	}

	// The unlock gate was missing entirely: a level-1 player could buy a holding
	// meant for level 55 simply by affording it, skipping the whole progression.
	q0 := sqlcdb.New(d.Pool)
	owner, err := q0.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	if int(owner.Level) < h.UnlockLevel {
		return nil, fmt.Errorf("%w: %s unlocks at level %d", ErrLevelTooLow, h.Name, h.UnlockLevel)
	}

	// Buying a holding changes the tax RATE, so accrual must be settled at the
	// old rate first. Otherwise the whole idle period since the last touch would
	// be retroactively paid at the new, higher rate.
	if err := d.settleTaxNow(ctx, playerID); err != nil {
		return nil, err
	}

	if err := d.buyLevel(ctx, playerID, wantSeq, func(q *sqlcdb.Queries, level int) (int64, error) {
		cost, ok := h.Cost(level)
		if !ok {
			return 0, ErrUpgradeMaxed
		}
		return cost, nil
	}, func(ctx context.Context, q *sqlcdb.Queries, level int) error {
		_, err := q.BuyHoldingLevel(ctx, sqlcdb.BuyHoldingLevelParams{
			PlayerID: playerID, HoldingID: holdingID, Level: int32(level),
		})
		return err
	}, func(ctx context.Context, q *sqlcdb.Queries) (int, error) {
		rows, err := q.ListHoldings(ctx, playerID)
		if err != nil {
			return 0, err
		}
		for _, r := range rows {
			if r.HoldingID == holdingID {
				return int(r.Level), nil
			}
		}
		return 0, nil
	}, "holding:"+holdingID); err != nil {
		return nil, err
	}
	return d.GetEstates(ctx, playerID)
}

// buyLevel is the shared transaction for both trees.
func (d Deps) buyLevel(
	ctx context.Context, playerID uuid.UUID, wantSeq int64,
	price func(*sqlcdb.Queries, int) (int64, error),
	apply func(context.Context, *sqlcdb.Queries, int) error,
	current func(context.Context, *sqlcdb.Queries) (int, error),
	reason string,
) error {
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
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

		level, err := current(ctx, q)
		if err != nil {
			return err
		}
		cost, err := price(q, level)
		if err != nil {
			return err
		}

		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: cost, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}
		if err := apply(ctx, q, level); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// The level moved under us, so the price we charged was for a
				// different level. Roll back rather than sell the wrong thing.
				return ErrStaleAction
			}
			return fmt.Errorf("apply level: %w", err)
		}
		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: reason, RefID: nil,
		})
	})
}

// settleTaxNow flushes accrual at the current rate.
func (d Deps) settleTaxNow(ctx context.Context, playerID uuid.UUID) error {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		return err
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return err
	}
	s := estates.SettleTax(
		estates.TaxState{Milli: p.TaxMilliAccrued, UpdatedAt: p.TaxUpdatedAt},
		eff.TaxMilliPerHour, eff.OfflineCapSeconds, d.Now())
	return q.SettleTax(ctx, sqlcdb.SettleTaxParams{
		ID: playerID, TaxMilliAccrued: s.Milli, TaxUpdatedAt: s.UpdatedAt,
	})
}

// ClaimTaxResult reports the collection.
type ClaimTaxResult struct {
	Collected int64     `json:"collected"`
	Snapshot  *Snapshot `json:"snapshot"`
}

// ClaimTax banks the pending idle income.
func (d Deps) ClaimTax(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*ClaimTaxResult, error) {
	var res ClaimTaxResult

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

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		now := d.Now()
		s := estates.SettleTax(
			estates.TaxState{Milli: p.TaxMilliAccrued, UpdatedAt: p.TaxUpdatedAt},
			eff.TaxMilliPerHour, eff.OfflineCapSeconds, now)

		gold := estates.Whole(s)
		if gold <= 0 {
			return ErrNoTax
		}

		after, err := q.ClaimTax(ctx, sqlcdb.ClaimTaxParams{
			ID: playerID, Gold: gold, TaxUpdatedAt: now, ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("claim tax: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: gold, BalanceAfter: after.Gold,
			Reason: "tax", RefID: nil,
		}); err != nil {
			return err
		}
		res.Collected = gold
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}
