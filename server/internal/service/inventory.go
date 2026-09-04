package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

var ErrItemEquipped = errors.New("unequip the item first")

// ItemView is one owned item as the client sees it.
type ItemView struct {
	ID         string `json:"id"`
	DefID      string `json:"def_id"`
	Name       string `json:"name"`
	Slot       string `json:"slot"`
	Tier       string `json:"tier"`
	Art        string `json:"art"`
	Ilvl       int64  `json:"ilvl"`
	QualityPct int64  `json:"quality_pct"`
	Masterwork bool   `json:"masterwork"`
	Attack     int64  `json:"attack"`
	Defense    int64  `json:"defense"`
	Speed      int64  `json:"speed"`
	Power      int64  `json:"power"`
	SellPrice  int64  `json:"sell_price"`
	Equipped   bool   `json:"equipped"`
}

// InventoryView is the Armory tab.
type InventoryView struct {
	Items    []ItemView           `json:"items"`
	Equipped map[string]*ItemView `json:"equipped"` // slot -> item, nil when empty
	Used     int64                `json:"used"`
	Cap      int64                `json:"cap"`
	Hero     HeroStats            `json:"hero"`
}

// HeroStats is the player's own combat contribution: allocated stat points plus
// whatever they are wearing.
type HeroStats struct {
	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	Speed   int64 `json:"speed"`
	Power   int64 `json:"power"`
}

func (d Deps) GetInventory(ctx context.Context, playerID uuid.UUID) (*InventoryView, error) {
	q := sqlcdb.New(d.Pool)

	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	rows, err := q.ListPlayerItems(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("list items: %w", err)
	}

	view := &InventoryView{
		Items:    make([]ItemView, 0, len(rows)),
		Equipped: map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil},
		Used:     int64(len(rows)),
		Cap:      inventoryCap,
	}
	for _, r := range rows {
		iv := d.itemView(r)
		view.Items = append(view.Items, iv)
		if r.EquippedOnHero {
			copyOf := iv
			view.Equipped[r.Slot] = &copyOf
		}
	}
	view.Hero = d.heroStats(p, view.Equipped)
	return view, nil
}

func (d Deps) itemView(r sqlcdb.AppPlayerItem) ItemView {
	inst := items.Instance{
		Slot: r.Slot, Tier: r.Tier,
		Attack: r.Attack, Defense: r.Defense, Speed: r.Speed,
		Ilvl: int64(r.Ilvl), QualityPct: int64(r.QualityPct), Masterwork: r.Masterwork,
	}
	name, art := r.DefID, r.DefID
	if def := d.Config.ItemDef(r.DefID); def != nil {
		name, art = def.Name, def.Art
	}
	return ItemView{
		ID: r.ID.String(), DefID: r.DefID, Name: name, Slot: r.Slot, Tier: r.Tier, Art: art,
		Ilvl: int64(r.Ilvl), QualityPct: int64(r.QualityPct), Masterwork: r.Masterwork,
		Attack: r.Attack, Defense: r.Defense, Speed: r.Speed,
		Power:     inst.Power(d.Config),
		SellPrice: items.SellPrice(d.Config, inst),
		Equipped:  r.EquippedOnHero,
	}
}

// heroStats combines allocated stat points with equipped gear.
func (d Deps) heroStats(p sqlcdb.AppPlayer, equipped map[string]*ItemView) HeroStats {
	// Stat points are worth more than a point of gear so that a player who never
	// gets a lucky drop still progresses. The multiplier is a tuning knob.
	const perStatPoint = 3

	h := HeroStats{
		Attack:  int64(p.StatAttack) * perStatPoint,
		Defense: int64(p.StatDefense) * perStatPoint,
	}
	for _, iv := range equipped {
		if iv == nil {
			continue
		}
		h.Attack += iv.Attack
		h.Defense += iv.Defense
		h.Speed += iv.Speed
	}
	h.Power = h.Attack + h.Defense + h.Speed*d.Config.Items.SpeedPowerWeightBP/10000
	return h
}

// Equip puts an item in its slot, replacing whatever was there.
func (d Deps) Equip(ctx context.Context, playerID, itemID uuid.UUID) (*InventoryView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		it, err := q.LockPlayerItem(ctx, sqlcdb.LockPlayerItemParams{ID: itemID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock item: %w", err)
		}
		if it.EquippedOnHero {
			return nil // already worn; equipping again is a no-op, not an error
		}

		// Clear the slot first. Doing it in one transaction means the partial
		// unique index never sees two items in the same slot, even transiently.
		if err := q.UnequipHeroSlot(ctx, sqlcdb.UnequipHeroSlotParams{
			PlayerID: playerID, Slot: it.Slot,
		}); err != nil {
			return fmt.Errorf("clear slot: %w", err)
		}
		return q.SetHeroEquipped(ctx, sqlcdb.SetHeroEquippedParams{
			ID: itemID, PlayerID: playerID, EquippedOnHero: true,
		})
	})
	if err != nil {
		return nil, err
	}
	return d.GetInventory(ctx, playerID)
}

// Unequip takes an item off.
func (d Deps) Unequip(ctx context.Context, playerID, itemID uuid.UUID) (*InventoryView, error) {
	q := sqlcdb.New(d.Pool)
	if _, err := q.GetPlayerItem(ctx, sqlcdb.GetPlayerItemParams{ID: itemID, PlayerID: playerID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load item: %w", err)
	}
	if err := q.SetHeroEquipped(ctx, sqlcdb.SetHeroEquippedParams{
		ID: itemID, PlayerID: playerID, EquippedOnHero: false,
	}); err != nil {
		return nil, fmt.Errorf("unequip: %w", err)
	}
	return d.GetInventory(ctx, playerID)
}

// SellResult is the outcome of selling.
type SellResult struct {
	Gained   int64  `json:"gained"`
	GoldLeft string `json:"gold_left"`
}

// Sell destroys an item for gold.
func (d Deps) Sell(ctx context.Context, playerID, itemID uuid.UUID, wantSeq int64) (*SellResult, error) {
	var res SellResult

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		switch {
		case wantSeq <= p.ActionSeq:
			return ErrStaleAction
		case wantSeq > p.ActionSeq+1:
			return fmt.Errorf("%w: expected %d, got %d", ErrStaleAction, p.ActionSeq+1, wantSeq)
		}

		it, err := q.LockPlayerItem(ctx, sqlcdb.LockPlayerItemParams{ID: itemID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock item: %w", err)
		}
		// Refusing to sell worn gear is a guardrail, not a rule: it stops the
		// misfire where a player sells the sword they are holding.
		if it.EquippedOnHero || it.EquippedSoldierID != nil {
			return ErrItemEquipped
		}

		price := items.SellPrice(d.Config, items.Instance{
			Slot: it.Slot, Tier: it.Tier,
			Attack: it.Attack, Defense: it.Defense, Speed: it.Speed,
		})

		if err := q.DeletePlayerItem(ctx, sqlcdb.DeletePlayerItemParams{
			ID: itemID, PlayerID: playerID,
		}); err != nil {
			return fmt.Errorf("delete item: %w", err)
		}

		after, err := q.CreditGold(ctx, sqlcdb.CreditGoldParams{
			ID: playerID, Gold: price, ActionSeq: wantSeq,
		})
		if err != nil {
			return fmt.Errorf("credit gold: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: price, BalanceAfter: after.Gold,
			Reason: "item_sell", RefID: strPtr(itemID.String()),
		}); err != nil {
			return fmt.Errorf("ledger: %w", err)
		}

		res = SellResult{Gained: price, GoldLeft: itoa(after.Gold)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}
