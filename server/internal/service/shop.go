package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

var (
	ErrAlreadyPurchased  = errors.New("that offer is already sold")
	ErrNotEnoughGold     = errors.New("not enough gold")
	ErrNotEnoughDiamonds = errors.New("not enough diamonds")
	ErrNothingToBuy      = errors.New("that would do nothing right now")
	ErrInventoryFull     = errors.New("inventory is full")
	ErrShopStale         = errors.New("the shop has refreshed")
)

// ShopView is the Market tab.
type ShopView struct {
	WindowID      int64       `json:"window_id"`
	SecondsLeft   int64       `json:"seconds_left"`
	Offers        []ShopOffer `json:"offers"`
	InventoryUsed int64       `json:"inventory_used"`
	InventoryCap  int64       `json:"inventory_cap"`

	// What the next reroll would cost, and whether it can be afforded. Shown so
	// the price is visible before the tap rather than after it.
	RerollCost    int64 `json:"reroll_cost"`
	RerollsUsed   int64 `json:"rerolls_used"`
	CanAffordRoll bool  `json:"can_afford_reroll"`
	// Rerolls left on the lord's day, of the day's allowance. At zero the
	// market cannot be rerolled until midnight, whatever the purse holds.
	RerollsLeft   int `json:"rerolls_left"`
	RerollsPerDay int `json:"rerolls_per_day"`
	// Rerolls Fresh Wares gives for nothing while it runs, not yet taken: the
	// next reroll costs no diamonds and leaves the day's allowance alone.
	FreeRerolls int `json:"free_rerolls"`
	// Seconds until Fresh Wares ends, while it runs.
	FreeEndsIn int64 `json:"free_ends_in,omitempty"`
}

type ShopOffer struct {
	Slot      int            `json:"slot"`
	Purchased bool           `json:"purchased"`
	Price     int64          `json:"price"`
	Item      items.Instance `json:"item"`
	// The item's Power, the one number a card can compare offers by. The card
	// showed a name and a price and nothing to weigh the price against.
	Power int64 `json:"power"`
}

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

	// Read before the upsert: a window is stamped with the luck it is rolled
	// with, and only when it turns.
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	windowID, secondsLeft := d.shopWindow()
	st, err := q.UpsertShopWindow(ctx, sqlcdb.UpsertShopWindowParams{
		PlayerID: playerID, WindowID: windowID, LuckBp: int32(eff.LuckBP),
	})
	if err != nil {
		return nil, fmt.Errorf("shop window: %w", err)
	}

	used, err := q.CountPlayerItems(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("count items: %w", err)
	}

	cost := rerollCost(d.Config, int64(st.RerollIndex))
	perDay := d.Config.Items.Shop.RerollsPerDay
	now := d.Now()
	var free int
	var freeEnds int64
	if h := d.runningHourly(now, gameconfig.HourlyFreeReroll); h != nil {
		free = d.hourlyUsesLeft(ctx, q, playerID, *h)
		if free > 0 {
			freeEnds = secondsUntil(h.EndsAt, now)
		}
	}
	return &ShopView{
		FreeRerolls:   free,
		FreeEndsIn:    freeEnds,
		RerollCost:    cost,
		RerollsUsed:   int64(st.RerollIndex),
		CanAffordRoll: p.Diamonds >= cost || free > 0,
		RerollsLeft:   max(0, perDay-shopRerollsToday(p, localDay(d.Now(), p.ResetOffsetMinutes))),
		RerollsPerDay: perDay,
		WindowID:      windowID,
		SecondsLeft:   secondsLeft,
		Offers:        d.rollOffers(playerID, st, int(p.Level), eff.ShopDiscount),
		InventoryUsed: used,
		InventoryCap:  d.bagCap(p),
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
func (d Deps) rollOffers(playerID uuid.UUID, st sqlcdb.AppShopState, level int, discountBP int64) []ShopOffer {
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

		// The luck the window was rolled WITH, not the player's luck right now.
		// Offers are recomputed on every GetShop and once more inside Buy; if
		// luck were read live, an override applied mid-window would change which
		// item is on the shelf -- not just its price, the way a discount does --
		// and the player would be charged for something they never saw.
		luckBP := int64(st.LuckBp)
		coef := items.EffectiveLuckCoef(shop.LuckCoef, luckBP)

		tier := items.RollTier(cfg, rng, shop.BaseWeights, coef, level)
		slot := []string{"weapon", "armor", "horse"}[rng.IntN(3)]
		// Shop stock is always at the player's own level, so old gear reliably
		// ages out and the shop stays relevant for the whole run.
		item := items.Roll(cfg, rng, slot, tier, int64(level), luckBP)

		out = append(out, ShopOffer{
			Slot:      i,
			Purchased: st.PurchasedMask&(1<<i) != 0,
			Price:     items.BuyPrice(cfg, item, discountBP),
			Item:      item,
			Power:     item.Power(cfg),
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

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		offers := d.rollOffers(playerID, st, int(p.Level), eff.ShopDiscount)
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
		if used >= d.bagCap(p) {
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

		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.Buys: 1, deeds.ShopGold: offer.Price})

		res = BuyResult{Item: it, Paid: offer.Price, GoldLeft: itoa(after.Gold)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func strPtr(s string) *string { return &s }

// rerollCost escalates within a window and resets when the window turns.
//
// Flat pricing would make a legendary a matter of patience with a wallet; an
// escalating one keeps the fifth reroll of a window a real decision. Diamonds
// only -- a gold reroll would be a way to convert income straight into rarity,
// which is the one thing the premium currency is not allowed to do either.
// ErrRerollsExhausted is a market reroll asked for after the day's last one.
var ErrRerollsExhausted = errors.New("you have used today's market rerolls")

// shopRerollsToday is how many market rerolls a lord has made on their day.
func shopRerollsToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.ShopRerollsDay.Valid || !p.ShopRerollsDay.Time.Equal(today) {
		return 0
	}
	return int(p.ShopRerollsUsed)
}

func rerollCost(cfg *gameconfig.Bundle, used int64) int64 {
	return cfg.Items.Shop.RerollBaseDiamonds + cfg.Items.Shop.RerollStepDiamonds*used
}

// RerollShop buys a fresh set of offers.
//
// Nothing about the offers is stored: they are a pure function of
// (secret, player, window, reroll index), so advancing the index IS the reroll.
// It also clears the purchase mask, because advancing the index replaces all
// six offers -- buying slot 3 again after a reroll is buying a different item,
// not the same one twice. Keeping the mask meant a slot the player had bought
// from stayed dead for the rest of the window while displaying a new item.
func (d Deps) RerollShop(ctx context.Context, playerID uuid.UUID, wantSeq int64) (*ShopView, error) {
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
		reff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}

		windowID, _ := d.shopWindow()
		st, err := q.UpsertShopWindow(ctx, sqlcdb.UpsertShopWindowParams{
			PlayerID: playerID, WindowID: windowID, LuckBp: int32(reff.LuckBP),
		})
		if err != nil {
			return fmt.Errorf("shop window: %w", err)
		}

		// Fresh Wares: a reroll for nothing, taken off the hour's allowance
		// rather than the day's, and still the player's sequenced action.
		if h := d.runningHourly(d.Now(), gameconfig.HourlyFreeReroll); h != nil {
			_, err := q.UseHourly(ctx, sqlcdb.UseHourlyParams{
				PlayerID: playerID, Hour: h.Hour, Max: int16(h.Event.Effect.Count),
			})
			switch {
			case err == nil:
				if _, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: playerID, ActionSeq: wantSeq}); err != nil {
					return fmt.Errorf("advance seq: %w", err)
				}
				if _, err := q.BumpReroll(ctx, sqlcdb.BumpRerollParams{PlayerID: playerID, WindowID: windowID}); err != nil {
					return fmt.Errorf("bump reroll: %w", err)
				}
				return nil
			case !errors.Is(err, pgx.ErrNoRows):
				return fmt.Errorf("use the hour: %w", err)
			}
		}

		// Counted from the locked row: two taps cannot both be the twentieth.
		today := localDay(d.Now(), p.ResetOffsetMinutes)
		used := shopRerollsToday(p, today)
		if used >= d.Config.Items.Shop.RerollsPerDay {
			return ErrRerollsExhausted
		}

		cost := rerollCost(d.Config, int64(st.RerollIndex))
		after, err := q.PayForReroll(ctx, sqlcdb.PayForRerollParams{
			ID: playerID, Diamonds: cost, ActionSeq: wantSeq,
			RerollsDay: pgtype.Date{Time: today, Valid: true}, RerollsUsed: int16(used + 1),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughDiamonds
			}
			return fmt.Errorf("pay for reroll: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, -cost, ledger.MarketReroll,
			fmt.Sprintf("window %d", windowID)); err != nil {
			return err
		}
		if _, err := q.BumpReroll(ctx, sqlcdb.BumpRerollParams{
			PlayerID: playerID, WindowID: windowID,
		}); err != nil {
			return fmt.Errorf("bump reroll: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetShop(ctx, playerID)
}
