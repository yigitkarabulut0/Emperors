package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/army"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

var (
	ErrNoSlot        = errors.New("that slot has not been bought")
	ErrSlotOccupied  = errors.New("slot is occupied")
	ErrSlotsMaxed    = errors.New("all soldier slots are bought")
	ErrLevelTooLow   = errors.New("your level is too low")
	ErrAlreadyMaxed  = errors.New("already at your level")
	ErrWrongSlotType = errors.New("that item does not fit that slot")
)

// ArmyView is the Barracks tab.
type ArmyView struct {
	Slots    []SlotView   `json:"slots"`
	Hero     UnitView     `json:"hero"`
	Totals   army.Totals  `json:"totals"`
	NextSlot *NextSlot    `json:"next_slot"`
	Recruits []RecruitOpt `json:"recruits"`
}

type SlotView struct {
	Index   int       `json:"index"`
	Soldier *UnitView `json:"soldier"`
}

type UnitView struct {
	ID        string               `json:"id"`
	Name      string               `json:"name"`
	IsHero    bool                 `json:"is_hero"`
	Type      string               `json:"type,omitempty"`
	Tier      string               `json:"tier,omitempty"`
	Level     int64                `json:"level"`
	Attack    int64                `json:"attack"`
	Defense   int64                `json:"defense"`
	Speed     int64                `json:"speed"`
	HP        int64                `json:"hp"`
	EHP       int64                `json:"ehp"`
	Equipped  map[string]*ItemView `json:"equipped"`
	TrainCost int64                `json:"train_cost,omitempty"`
	CanTrain  bool                 `json:"can_train"`
}

type NextSlot struct {
	Index     int   `json:"index"`
	Cost      int64 `json:"cost"`
	LevelGate int   `json:"level_gate"`
	Unlocked  bool  `json:"unlocked"`
	Free      bool  `json:"free"`
}

type RecruitOpt struct {
	TypeID string `json:"type_id"`
	Name   string `json:"name"`
	Cost   int64  `json:"cost"`
	Free   bool   `json:"free"`
}

// GetArmy assembles the roster, its gear and the resulting Might.
func (d Deps) GetArmy(ctx context.Context, playerID uuid.UUID) (*ArmyView, error) {
	q := sqlcdb.New(d.Pool)

	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	soldiers, err := q.ListSoldiers(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list soldiers: %w", err)
	}
	allItems, err := q.ListPlayerItems(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list items: %w", err)
	}

	heroGear := map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}
	soldierGear := map[uuid.UUID]map[string]*ItemView{}
	for _, r := range allItems {
		iv := d.itemView(r)
		switch {
		case r.EquippedOnHero:
			c := iv
			heroGear[r.Slot] = &c
		case r.EquippedSoldierID != nil:
			m, ok := soldierGear[*r.EquippedSoldierID]
			if !ok {
				m = map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}
				soldierGear[*r.EquippedSoldierID] = m
			}
			c := iv
			m[r.Slot] = &c
		}
	}

	// Slots is initialised rather than left nil: a nil slice marshals to JSON
	// null, and a client iterating `slots` would crash on a player who has not
	// bought one yet. Every array in a response should be [] when empty.
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	view := &ArmyView{
		Slots:    []SlotView{},
		Recruits: d.recruitOptions(int64(p.Level), d.freeRecruitAvailable(p)),
	}
	units := make([]army.Unit, 0, len(soldiers)+1)

	hero := d.heroUnit(p, heroGear)
	view.Hero = hero
	units = append(units, toArmyUnit(hero))

	bySlot := map[int]*UnitView{}
	for _, s := range soldiers {
		gear := soldierGear[s.ID]
		if gear == nil {
			gear = map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}
		}
		uv := d.soldierUnit(p, s, gear, eff)
		bySlot[int(s.SlotIndex)] = &uv
		units = append(units, toArmyUnit(uv))
	}

	for i := 1; i <= int(p.SoldierSlots); i++ {
		view.Slots = append(view.Slots, SlotView{Index: i, Soldier: bySlot[i]})
	}

	if cost, gate, ok := d.Config.SlotCost(int(p.SoldierSlots) + 1); ok {
		free := d.freeSlotAvailable(p)
		if free {
			cost = 0
		}
		view.NextSlot = &NextSlot{
			Index: int(p.SoldierSlots) + 1, Cost: cost, LevelGate: gate,
			Unlocked: int(p.Level) >= gate || free, Free: free,
		}
	}

	view.Totals = army.Sum(units)
	return view, nil
}

func (d Deps) heroUnit(p sqlcdb.AppPlayer, gear map[string]*ItemView) UnitView {
	atk, def := army.HeroBase(d.Config, int64(p.Level), int64(p.StatAttack), int64(p.StatDefense))
	var spd int64
	for _, iv := range gear {
		if iv == nil {
			continue
		}
		atk += iv.Attack
		def += iv.Defense
		spd += iv.Speed
	}
	hp := army.HeroHP(d.Config, int64(p.Level), def)
	return UnitView{
		ID: p.ID.String(), Name: p.DisplayName, IsHero: true, Level: int64(p.Level),
		Attack: atk, Defense: def, Speed: spd, HP: hp,
		EHP:      army.EffectiveHP(d.Config, hp, def, int64(p.Level)),
		Equipped: gear,
	}
}

func (d Deps) soldierUnit(p sqlcdb.AppPlayer, s sqlcdb.AppSoldier, gear map[string]*ItemView, eff estates.Effects) UnitView {
	atk, def, baseHP := army.SoldierBase(d.Config, s.TypeID, s.Tier, int64(s.Level))
	var spd int64
	for _, iv := range gear {
		if iv == nil {
			continue
		}
		atk += iv.Attack
		def += iv.Defense
		spd += iv.Speed
	}

	// Armoury, Bulwark and Stables lift the soldier AFTER gear, so the upgrade
	// scales the whole unit rather than only its base.
	atk = atk * (10000 + eff.SoldierAtkBP) / 10000
	def = def * (10000 + eff.SoldierDefBP) / 10000
	spd = spd * (10000 + eff.SoldierSpdBP) / 10000
	hp := army.UnitHP(d.Config, baseHP, def, int64(p.Level))

	uv := UnitView{
		ID: s.ID.String(), Name: s.Name, Type: s.TypeID, Tier: s.Tier, Level: int64(s.Level),
		Attack: atk, Defense: def, Speed: spd, HP: hp,
		EHP:      army.EffectiveHP(d.Config, hp, def, int64(p.Level)),
		Equipped: gear,
	}
	if s.Level < p.Level {
		uv.CanTrain = true
		uv.TrainCost = trainCost(d.Config, int64(s.Level), s.Tier)
	}
	return uv
}

func toArmyUnit(u UnitView) army.Unit {
	return army.Unit{
		ID: u.ID, Name: u.Name, IsHero: u.IsHero, Type: u.Type, Tier: u.Tier, Level: u.Level,
		Attack: u.Attack, Defense: u.Defense, Speed: u.Speed, HP: u.HP, EHP: u.EHP,
	}
}

// trainCost grows as 1.09^level, which makes it an effectively unbounded gold
// sink — the thing a long-lived economy needs most.
func trainCost(cfg *gameconfig.Bundle, fromLevel int64, tier string) int64 {
	t := cfg.Soldiers.Train
	cost := t.Base * 10000
	for i := int64(0); i < fromLevel; i++ {
		cost = cost * t.GrowthBP / 10000
	}
	cost = cost * cfg.Items.TierMultBP[tier] / 10000
	cost = (cost + 5000) / 10000
	if cost < 1 {
		return 1
	}
	return cost
}

func (d Deps) recruitOptions(level int64, freeRecruit bool) []RecruitOpt {
	out := make([]RecruitOpt, 0, len(d.Config.Soldiers.Types))
	for i := range d.Config.Soldiers.Types {
		t := &d.Config.Soldiers.Types[i]
		cost := recruitCost(d.Config, t, level)
		if freeRecruit {
			cost = 0
		}
		out = append(out, RecruitOpt{TypeID: t.ID, Name: t.Name, Cost: cost, Free: freeRecruit})
	}
	return out
}

// freeSlotAvailable reports whether this player is owed the onboarding slot.
func (d Deps) freeSlotAvailable(p sqlcdb.AppPlayer) bool {
	o := d.Config.Soldiers.Onboarding
	return o.FreeSlotAtLevel > 0 && !p.FreeSlotClaimed &&
		p.SoldierSlots == 0 && int(p.Level) >= o.FreeSlotAtLevel
}

// freeRecruitAvailable reports whether the next recruit is the free one.
func (d Deps) freeRecruitAvailable(p sqlcdb.AppPlayer) bool {
	return d.Config.Soldiers.Onboarding.FreeFirstRecruit && !p.FreeRecruitClaimed
}

func recruitCost(cfg *gameconfig.Bundle, t *gameconfig.SoldierType, level int64) int64 {
	num := t.BaseCost * (10000 + cfg.Soldiers.RecruitCostPerLevelBP*level)
	return (num + 5000) / 10000
}

// BuySlot purchases the next soldier slot.
func (d Deps) BuySlot(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*ArmyView, error) {
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

		next := int(p.SoldierSlots) + 1
		cost, gate, ok := d.Config.SlotCost(next)
		if !ok {
			return ErrSlotsMaxed
		}

		// The onboarding slot is granted, not sold. Without it the Barracks
		// unlocks visibly unreachable in a first session.
		if d.freeSlotAvailable(p) {
			if _, err := q.ClaimFreeSlot(ctx, sqlcdb.ClaimFreeSlotParams{
				ID: playerID, ActionSeq: wantSeq,
			}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrStaleAction // someone already claimed it
				}
				return fmt.Errorf("claim free slot: %w", err)
			}
			return nil
		}

		if int(p.Level) < gate {
			return fmt.Errorf("%w: slot %d needs level %d", ErrLevelTooLow, next, gate)
		}

		// soldier_slots is in the WHERE clause as well, so two concurrent buys
		// cannot both see the same count and both succeed.
		after, err := q.BuySoldierSlot(ctx, sqlcdb.BuySoldierSlotParams{
			ID: playerID, Gold: cost, ActionSeq: wantSeq, SoldierSlots: p.SoldierSlots,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("buy slot: %w", err)
		}
		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: "soldier_slot", RefID: strPtr(fmt.Sprint(next)),
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetArmy(ctx, playerID)
}

// RecruitResult reports what turned up.
type RecruitResult struct {
	Soldier  UnitView  `json:"soldier"`
	Paid     int64     `json:"paid"`
	Replaced bool      `json:"replaced"`
	Army     *ArmyView `json:"army"`
}

// Recruit fills a slot, replacing whatever was there.
func (d Deps) Recruit(ctx context.Context, playerID uuid.UUID, slotIndex int, typeID string, wantSeq int64) (*RecruitResult, error) {
	t := d.Config.SoldierType(typeID)
	if t == nil {
		return nil, ErrNotFound
	}

	var res RecruitResult
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
		if slotIndex < 1 || slotIndex > int(p.SoldierSlots) {
			return ErrNoSlot
		}

		existing, err := q.ListSoldiers(ctx, playerID)
		if err != nil {
			return fmt.Errorf("list soldiers: %w", err)
		}
		var replacing *sqlcdb.AppSoldier
		for i := range existing {
			if int(existing[i].SlotIndex) == slotIndex {
				replacing = &existing[i]
			}
		}

		free := d.freeRecruitAvailable(p)
		cost := recruitCost(d.Config, t, int64(p.Level))
		var after sqlcdb.AppPlayer
		if free {
			cost = 0
			after, err = q.ClaimFreeRecruit(ctx, sqlcdb.ClaimFreeRecruitParams{
				ID: playerID, ActionSeq: wantSeq,
			})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrStaleAction
				}
				return fmt.Errorf("claim free recruit: %w", err)
			}
		} else {
			after, err = q.SpendGold(ctx, sqlcdb.SpendGoldParams{
				ID: playerID, Gold: cost, ActionSeq: wantSeq,
			})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughGold
				}
				return fmt.Errorf("spend gold: %w", err)
			}
		}

		// Seeded from a counter that only ever moves forward, so a retried
		// request cannot reroll for a better tier.
		rng := game.SeedForString(d.ShopSecret, playerID.String(),
			uint64(wantSeq), uint64(slotIndex), 0xA11CE)
		tier := items.RollTier(d.Config, rng, t.Weights, t.LuckCoef, int(p.Level))

		// The very first soldier has a tier floor. A player whose free recruit
		// rolls the worst possible outcome learns the wrong lesson about the
		// system on the one roll they are guaranteed to remember.
		if free {
			if floor := d.Config.Soldiers.Onboarding.FirstRecruitTierFloor; floor != "" {
				if d.Config.TierRank(tier) < d.Config.TierRank(floor) {
					tier = floor
				}
			}
		}

		if replacing != nil {
			// The outgoing soldier's gear goes back to the bag rather than being
			// destroyed with them.
			if err := q.ReleaseSoldierItems(ctx, sqlcdb.ReleaseSoldierItemsParams{
				PlayerID: playerID, EquippedSoldierID: &replacing.ID,
			}); err != nil {
				return fmt.Errorf("release gear: %w", err)
			}
			res.Replaced = true
		}

		s, err := q.UpsertSoldier(ctx, sqlcdb.UpsertSoldierParams{
			PlayerID: playerID, SlotIndex: int32(slotIndex), TypeID: typeID, Tier: tier,
			Level: p.Level, Name: t.Name, RolledConfigVersion: int32(d.Config.Version),
		})
		if err != nil {
			return fmt.Errorf("upsert soldier: %w", err)
		}
		if cost > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
				Reason: "recruit", RefID: strPtr(s.ID.String()),
			}); err != nil {
				return fmt.Errorf("ledger: %w", err)
			}
		}

		res.Paid = cost
		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		res.Soldier = d.soldierUnit(p, s, map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil}, eff)
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Army, err = d.GetArmy(ctx, playerID)
	return &res, err
}

// Train raises a soldier one level toward the player's.
func (d Deps) Train(ctx context.Context, playerID, soldierID uuid.UUID, wantSeq int64) (*ArmyView, error) {
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

		s, err := q.LockSoldier(ctx, sqlcdb.LockSoldierParams{ID: soldierID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock soldier: %w", err)
		}
		if s.Level >= p.Level {
			return ErrAlreadyMaxed
		}

		cost := trainCost(d.Config, int64(s.Level), s.Tier)
		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: cost, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}
		if _, err := q.SetSoldierLevel(ctx, sqlcdb.SetSoldierLevelParams{
			ID: soldierID, PlayerID: playerID, Level: s.Level + 1,
		}); err != nil {
			return fmt.Errorf("set level: %w", err)
		}
		return q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -cost, BalanceAfter: after.Gold,
			Reason: "train", RefID: strPtr(soldierID.String()),
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetArmy(ctx, playerID)
}

// EquipSoldier moves an item onto a soldier.
func (d Deps) EquipSoldier(ctx context.Context, playerID, soldierID, itemID uuid.UUID) (*ArmyView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		if _, err := q.LockSoldier(ctx, sqlcdb.LockSoldierParams{ID: soldierID, PlayerID: playerID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock soldier: %w", err)
		}
		it, err := q.LockPlayerItem(ctx, sqlcdb.LockPlayerItemParams{ID: itemID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock item: %w", err)
		}

		if err := q.UnequipSoldierSlot(ctx, sqlcdb.UnequipSoldierSlotParams{
			PlayerID: playerID, EquippedSoldierID: &soldierID, Slot: it.Slot,
		}); err != nil {
			return fmt.Errorf("clear soldier slot: %w", err)
		}
		return q.SetSoldierEquipped(ctx, sqlcdb.SetSoldierEquippedParams{
			ID: itemID, PlayerID: playerID, EquippedSoldierID: &soldierID,
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetArmy(ctx, playerID)
}

// checkSeq enforces the per-player idempotency counter.
func checkSeq(p sqlcdb.AppPlayer, wantSeq int64) error {
	switch {
	case p.State == "banned":
		return ErrPlayerBanned
	case wantSeq <= p.ActionSeq:
		return ErrStaleAction
	case wantSeq > p.ActionSeq+1:
		return fmt.Errorf("%w: expected %d, got %d", ErrStaleAction, p.ActionSeq+1, wantSeq)
	}
	return nil
}

// DismissResult is what the player gets back for letting a soldier go.
type DismissResult struct {
	Refund   int64     `json:"refund"`
	GoldLeft string    `json:"gold_left"`
	Army     *ArmyView `json:"army"`
}

// dismissRefund is what a soldier is worth on the way out.
//
// Deliberately a fraction of what recruiting THAT TYPE COSTS RIGHT NOW, not of
// what this particular soldier once cost. Recruit price rises with the player's
// level, so pricing the refund off the soldier's own stored level would let a
// trained soldier refund more than an untrained one and turn Train into an
// investment. Off the current price, dismiss-and-recruit always costs the same
// fraction of a recruit, whatever the player has done in between.
func dismissRefund(cfg *gameconfig.Bundle, t *gameconfig.SoldierType, level int64) int64 {
	ratio := cfg.Items.Price.SellRatioBP
	return recruitCost(cfg, t, level) * ratio / 10000
}

// Dismiss releases a soldier, frees the slot and refunds part of the recruit
// price. This is the reroll loop: a player hunting a legendary recruits,
// dismisses, and recruits again, paying the difference every cycle.
func (d Deps) Dismiss(ctx context.Context, playerID, soldierID uuid.UUID, wantSeq int64) (*DismissResult, error) {
	var res DismissResult
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

		s, err := q.LockSoldier(ctx, sqlcdb.LockSoldierParams{ID: soldierID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock soldier: %w", err)
		}

		// Gear goes back to the bag. Destroying it with the soldier would make a
		// reroll cost far more than the refund suggests.
		if err := q.ReleaseSoldierItems(ctx, sqlcdb.ReleaseSoldierItemsParams{
			PlayerID: playerID, EquippedSoldierID: &s.ID,
		}); err != nil {
			return fmt.Errorf("release gear: %w", err)
		}
		if err := q.DeleteSoldier(ctx, sqlcdb.DeleteSoldierParams{
			ID: soldierID, PlayerID: playerID,
		}); err != nil {
			return fmt.Errorf("delete soldier: %w", err)
		}

		refund := int64(0)
		if t := d.Config.SoldierType(s.TypeID); t != nil {
			refund = dismissRefund(d.Config, t, int64(p.Level))
		}
		after, err := q.CreditGold(ctx, sqlcdb.CreditGoldParams{
			ID: playerID, Gold: refund, ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("credit gold: %w", err)
		}
		if refund > 0 {
			if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
				PlayerID: playerID, Delta: refund, BalanceAfter: after.Gold,
				Reason: "soldier_dismiss", RefID: strPtr(soldierID.String()),
			}); err != nil {
				return fmt.Errorf("ledger: %w", err)
			}
		}

		res = DismissResult{Refund: refund, GoldLeft: itoa(after.Gold)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Army, err = d.GetArmy(ctx, playerID)
	return &res, err
}
