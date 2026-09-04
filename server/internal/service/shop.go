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
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

var (
	ErrAlreadyPurchased = errors.New("that offer is already sold")
	ErrNotEnoughGold    = errors.New("not enough gold")
	ErrInventoryFull    = errors.New("inventory is full")
	ErrShopStale        = errors.New("the shop has refreshed")
)

// ShopView is the Market tab.
type ShopView struct {
	WindowID      int64       `json:"window_id"`
	SecondsLeft   int64       `json:"seconds_left"`
	Offers        []ShopOffer `json:"offers"`
	InventoryUsed int64       `json:"inventory_used"`
	InventoryCap  int64       `json:"inventory_cap"`
}

type ShopOffer struct {
	Slot      int            `json:"slot"`
	Purchased bool           `json:"purchased"`
	Price     int64          `json:"price"`
	Item      items.Instance `json:"item"`
}

// inventoryCap bounds the largest player-owned table. It is also a design knob:
// forcing a choice about what to keep is what makes selling and the Collection
// meaningful rather than optional.
const inventoryCap = 150

// GetShop returns the current offers, rolling the window forward if needed.
func (d Deps) GetShop(ctx context.Context, playerID uuid.UUID) (*ShopView, error) {
	q := sqlcdb.New(d.Pool)

	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}

	windowID, secondsLeft := d.shopWindow()
	st, err := q.UpsertShopWindow(ctx, sqlcdb.UpsertShopWindowParams{
		PlayerID: playerID, WindowID: windowID,
	})
	if err != nil {
		return nil, fmt.Errorf("shop window: %w", err)
	}

	used, err := q.CountPlayerItems(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("count items: %w", err)
	}

	return &ShopView{
		WindowID:      windowID,
		SecondsLeft:   secondsLeft,
		Offers:        d.rollOffers(playerID, st, int(p.Level)),
		InventoryUsed: used,
		InventoryCap:  inventoryCap,
	}, nil
}

// shopWindow returns the current 5-minute window index and the seconds left in it.
func (d Deps) shopWindow() (int64, int64) {
	w := d.Config.Items.Shop.WindowSeconds
	if w <= 0 {
		w = 300
	}
	now := d.Now().Unix()
	id := now / w
	return id, w - (now % w)
}

// rollOffers recomputes the shelf. Nothing is stored: the same inputs always
// produce the same items, so a retry cannot reroll and an auditor can replay
// exactly what a player was shown.
func (d Deps) rollOffers(playerID uuid.UUID, st sqlcdb.AppShopState, level int) []ShopOffer {
	cfg := d.Config
	shop := cfg.Items.Shop
	slots := shop.Slots
	if slots <= 0 {
		slots = 6
	}

	out := make([]ShopOffer, 0, slots)
	for i := 0; i < slots; i++ {
		rng := game.SeedForString(d.ShopSecret, playerID.String(),
			uint64(st.WindowID), uint64(st.RerollIndex), uint64(i))

		tier := items.RollTier(cfg, rng, shop.BaseWeights, shop.LuckCoef, level)
		slot := []string{"weapon", "armor", "horse"}[rng.IntN(3)]
		// Shop stock is always at the player's own level, so old gear reliably
		// ages out and the shop stays relevant for the whole run.
		item := items.Roll(cfg, rng, slot, tier, int64(level))

		out = append(out, ShopOffer{
			Slot:      i,
			Purchased: st.PurchasedMask&(1<<i) != 0,
			Price:     items.BuyPrice(cfg, item, 0),
			Item:      item,
		})
	}
	return out
}

// BuyResult is the outcome of a purchase.
type BuyResult struct {
	Item     items.Instance `json:"item"`
	Paid     int64          `json:"paid"`
	GoldLeft string         `json:"gold_left"`
}

// Buy purchases one shop slot.
func (d Deps) Buy(ctx context.Context, playerID uuid.UUID, slot int, wantSeq int64) (*BuyResult, error) {
	var res BuyResult

	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)

		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if p.State == "banned" {
			return ErrPlayerBanned
		}
		switch {
		case wantSeq <= p.ActionSeq:
			return ErrStaleAction
		case wantSeq > p.ActionSeq+1:
			return fmt.Errorf("%w: expected %d, got %d", ErrStaleAction, p.ActionSeq+1, wantSeq)
		}

		st, err := q.LockShopState(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrShopStale
			}
			return fmt.Errorf("lock shop: %w", err)
		}

		// The window is checked INSIDE the transaction. Otherwise a request that
		// arrives just as the window rolls could buy an item from the shelf the
		// player was looking at a moment ago, at the old price.
		windowID, _ := d.shopWindow()
		if st.WindowID != windowID {
			return ErrShopStale
		}

		offers := d.rollOffers(playerID, st, int(p.Level))
		if slot < 0 || slot >= len(offers) {
			return ErrNotFound
		}
		offer := offers[slot]
		if offer.Purchased {
			return ErrAlreadyPurchased
		}

		used, err := q.CountPlayerItems(ctx, playerID)
		if err != nil {
			return fmt.Errorf("count items: %w", err)
		}
		if used >= inventoryCap {
			return ErrInventoryFull
		}

		// Conditional UPDATE: the WHERE clause carries the affordability check, so
		// the balance cannot go negative even if something slipped past the lock.
		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: offer.Price, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("spend gold: %w", err)
		}

		it := offer.Item
		row, err := q.InsertPlayerItem(ctx, sqlcdb.InsertPlayerItemParams{
			PlayerID: playerID, DefID: it.DefID, Slot: it.Slot, Tier: it.Tier,
			Ilvl: int32(it.Ilvl), QualityPct: int32(it.QualityPct), Masterwork: it.Masterwork,
			Attack: it.Attack, Defense: it.Defense, Speed: it.Speed,
			AcquiredFrom: "shop", RolledConfigVersion: int32(d.Config.Version),
		})
		if err != nil {
			return fmt.Errorf("insert item: %w", err)
		}

		if _, err := q.MarkShopSlotPurchased(ctx, sqlcdb.MarkShopSlotPurchasedParams{
			PlayerID: playerID, PurchasedMask: int32(1 << slot),
		}); err != nil {
			return fmt.Errorf("mark purchased: %w", err)
		}

		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -offer.Price, BalanceAfter: after.Gold,
			Reason: "shop_buy", RefID: strPtr(row.ID.String()),
		}); err != nil {
			return fmt.Errorf("ledger: %w", err)
		}

		res = BuyResult{Item: it, Paid: offer.Price, GoldLeft: itoa(after.Gold)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func strPtr(s string) *string { return &s }
