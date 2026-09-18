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
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// StoreGood is one thing diamonds buy.
type StoreGood struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// The card's heading and its two short lines. The Shop drew the painting's
	// own "30M SHIELD" over a server that sells eight hours, and got the eight by
	// running a regular expression over Blurb.
	Title   string `json:"title"`
	Caption string `json:"caption"`
	// The quantity the card shows beside its icon: energy restored, or hours of
	// protection.
	Amount   int64  `json:"amount"`
	Blurb    string `json:"blurb"`
	Icon     string `json:"icon"`
	Diamonds int64  `json:"diamonds"`
	// Whether buying right now would do anything: a full pool cannot be refilled
	// and a standing shield should not be paid for twice.
	Useful bool `json:"useful"`
	// Whether the player holds the diamonds for it, so BUY can say so before
	// the tap rather than after it.
	Affordable bool   `json:"affordable"`
	Note       string `json:"note,omitempty"`
	// For the refill: how many of the day's refills are taken and how many the
	// day allows. The caption already says it in words; these are for anything
	// that wants to draw it.
	RefillsUsed  int `json:"refills_used,omitempty"`
	RefillsLimit int `json:"refills_limit,omitempty"`
	// What it costs off sale, while a sale (Quartermaster's Sale) has it
	// cheaper: the card strikes this through beside Diamonds. Zero otherwise.
	RegularDiamonds int64 `json:"regular_diamonds,omitempty"`
	// Seconds until the sale ends, while one runs.
	SaleEndsIn int64 `json:"sale_ends_in,omitempty"`
	// The token that pays for this good instead of diamonds, and how many the
	// player holds. BUY offers "use a potion" while there are any.
	TokenID   string `json:"token_id,omitempty"`
	TokenName string `json:"token_name,omitempty"`
	Tokens    int64  `json:"tokens"`
}

// Paying for a good.
const (
	PayDiamonds = "diamonds"
	PayToken    = "token"
)

// ErrNoToken is a good paid for with a token the player does not hold.
var ErrNoToken = errors.New("you have none of those left")

// goodTokens is the token that can pay for each diamond good.
var goodTokens = map[string]string{"energy_refill": "energy_potion", "shield": "shield_8h"}

// tokenCounts is what the player holds, by token.
func tokenCounts(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (map[string]int64, error) {
	rows, err := q.ListTokens(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("tokens: %w", err)
	}
	out := make(map[string]int64, len(rows))
	for _, r := range rows {
		out[r.Token] = r.Qty
	}
	return out, nil
}

// ErrRefillsExhausted is a refill asked for after the day's last one.
var ErrRefillsExhausted = errors.New("you have used today's refills")

// refillsUsedToday is how many refills the player has taken on their local day.
// A count stamped with another day is yesterday's, and reads as none.
func refillsUsedToday(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.RefillsDay.Valid || !p.RefillsDay.Time.Equal(today) {
		return 0
	}
	return int(p.RefillsUsed)
}

// refillQuote prices this player's next refill of the day -- at Quartermaster's
// Sale's price while it runs. The store's card and the purchase both price
// through here, so the number on the button is the number charged.
func (d Deps) refillQuote(p sqlcdb.AppPlayer, now time.Time) (economy.RefillQuote, time.Time) {
	today := localDay(now, p.ResetOffsetMinutes)
	q := economy.QuoteRefill(d.Config.Progression.Store.EnergyRefillPrices, d.freeRefills(p, now),
		refillsUsedToday(p, today))
	if h := d.runningHourly(now, gameconfig.HourlyRefillDiscount); h != nil {
		q = economy.OnSale(q, h.Event.Effect.BP)
	}
	return q, today
}

// StoreView is the diamond half of the Shop screen.
type StoreView struct {
	Diamonds int64       `json:"diamonds"`
	Goods    []StoreGood `json:"goods"`
	// The flasks the lord holds, drunk with /v1/tokens/use: never bought, so
	// kept out of Goods, which a build before them would offer to sell.
	Flasks []FlaskGood `json:"flasks"`
}

// GetStore lists what diamonds buy and whether each is worth buying now.
func (d Deps) GetStore(ctx context.Context, playerID uuid.UUID) (*StoreView, error) {
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
	settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
	full := economy.Whole(settled) >= maxEnergy

	shielded := p.ShieldUntil != nil && p.ShieldUntil.After(now)
	cfg := d.Config.Progression.Store

	quote, _ := d.refillQuote(p, now)
	refill := StoreGood{
		ID: "energy_refill", Name: "Full Energy", Icon: "currency/bolt",
		Title: "ENERGY REFILL", Amount: maxEnergy,
		Blurb: fmt.Sprintf("Fill your pool back to %d right now. %d refills a day, each dearer than the last; the count resets at midnight.",
			maxEnergy, quote.Limit),
		Diamonds: quote.Price, Useful: !full && quote.Available,
		RefillsUsed: quote.Number - 1, RefillsLimit: quote.Limit,
	}
	if quote.Regular > quote.Price {
		refill.RegularDiamonds = quote.Regular
		if h := d.runningHourly(now, gameconfig.HourlyRefillDiscount); h != nil {
			refill.SaleEndsIn = secondsUntil(h.EndsAt, now)
		}
	}
	switch {
	case !quote.Available:
		refill.Caption = "No refills left today"
		refill.RefillsUsed = quote.Limit
		refill.Note = "you have used today's refills"
	case full:
		refill.Caption = fmt.Sprintf("Refill %d of %d today", quote.Number, quote.Limit)
		refill.Note = "your pool is already full"
	default:
		refill.Caption = fmt.Sprintf("Refill %d of %d today", quote.Number, quote.Limit)
	}

	shield := StoreGood{
		ID: "shield", Name: "Protection", Icon: "upgrades/bulwark",
		Title:   fmt.Sprintf("%dH SHIELD", cfg.ShieldHours),
		Caption: fmt.Sprintf("Protects your city\nfor %d hours", cfg.ShieldHours),
		Amount:  cfg.ShieldHours,
		// The buyer must read the one way it ends early before paying for it.
		Blurb: fmt.Sprintf("No one can raid you for %d hours. Raiding someone yourself ends it.",
			cfg.ShieldHours),
		Diamonds: cfg.ShieldDiamonds, Useful: !shielded,
	}
	if shielded {
		shield.Note = "you are already protected"
	}

	held, err := tokenCounts(ctx, q, playerID)
	if err != nil {
		return nil, err
	}
	goods := []StoreGood{refill, shield}
	for i := range goods {
		g := &goods[i]
		g.Affordable = p.Diamonds >= g.Diamonds
		if id := goodTokens[g.ID]; id != "" {
			if t := d.Config.Token(id); t != nil {
				g.TokenID, g.TokenName, g.Tokens = id, t.Name, held[id]
			}
		}
	}
	return &StoreView{Diamonds: p.Diamonds, Goods: goods,
		Flasks: d.flaskGoods(held, economy.Whole(settled), maxEnergy)}, nil
}

// BuyStoreGood buys a diamond good, paid for with diamonds or with the token
// that stands for it (an energy potion, a protection charter).
//
// Refusing to sell something that would do nothing is deliberate: a player who
// pays twenty diamonds for a shield they already have has been taken, and a
// premium currency you cannot waste by accident is one people trust.
//
// A refill paid with a potion is still one of the day's refills. However a
// refill is paid for, the day's bought energy stays inside the same limit.
func (d Deps) BuyStoreGood(ctx context.Context, playerID uuid.UUID, good, pay string, wantSeq int64) (*Snapshot, error) {
	cfg := d.Config.Progression.Store
	switch pay {
	case "", PayDiamonds:
		pay = PayDiamonds
	case PayToken:
		if goodTokens[good] == "" {
			return nil, ErrNotFound
		}
	default:
		return nil, ErrNotFound
	}

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

		switch good {
		case "energy_refill":
			// Which refill of the day this is decides its price, and it is read
			// from the locked row: two taps cannot both buy "the first".
			quote, today := d.refillQuote(p, now)
			if !quote.Available {
				return ErrRefillsExhausted
			}
			settled, maxEnergy, _ := settleEnergy(d.Config, p, eff, now)
			if economy.Whole(settled) >= maxEnergy {
				return ErrNothingToBuy
			}
			price := quote.Price
			if pay == PayToken {
				if err := spendToken(ctx, q, playerID, goodTokens[good]); err != nil {
					return err
				}
				price = 0
			}
			filled := economy.Refill(maxEnergy, now)
			after, err := q.BuyEnergyRefill(ctx, sqlcdb.BuyEnergyRefillParams{
				ID: playerID, Diamonds: price,
				EnergyMilli: filled.Milli, EnergyUpdatedAt: filled.UpdatedAt,
				RefillsDay:  pgtype.Date{Time: today, Valid: true},
				RefillsUsed: int16(quote.Number),
				ActionSeq:   wantSeq,
			})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughDiamonds
				}
				return fmt.Errorf("refill: %w", err)
			}
			if err := ledger.Diamonds(ctx, q, p, after, -price,
				ledger.EnergyRefill, fmt.Sprintf("%s #%d", today.Format("2006-01-02"), quote.Number)); err != nil {
				return err
			}

		case "shield":
			if p.ShieldUntil != nil && p.ShieldUntil.After(now) {
				return ErrNothingToBuy
			}
			price := cfg.ShieldDiamonds
			if pay == PayToken {
				if err := spendToken(ctx, q, playerID, goodTokens[good]); err != nil {
					return err
				}
				price = 0
			}
			until := now.Add(time.Duration(cfg.ShieldHours) * time.Hour)
			after, err := q.BuyShield(ctx, sqlcdb.BuyShieldParams{
				ID: playerID, Diamonds: price,
				ShieldUntil: &until, ActionSeq: wantSeq,
			})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughDiamonds
				}
				return fmt.Errorf("shield: %w", err)
			}
			if err := ledger.Diamonds(ctx, q, p, after, -price, ledger.Shield, ""); err != nil {
				return err
			}

		default:
			return ErrNotFound
		}
		return nil
	})
	if errors.Is(err, ErrRefillsExhausted) {
		// The day's refills gone with energy wanted: the moment A Second Wind is
		// offered. Its own transaction: this one has rolled back.
		d.fireTriggerOffer(ctx, playerID, gameconfig.TriggerEnergyEmpty)
	}
	if err != nil {
		return nil, err
	}
	return d.GetState(ctx, playerID)
}

// spendToken uses one token, or refuses when the player holds none.
func spendToken(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, token string) error {
	if _, err := q.SpendToken(ctx, sqlcdb.SpendTokenParams{PlayerID: playerID, Token: token, Qty: 1}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoToken
		}
		return fmt.Errorf("spend %s: %w", token, err)
	}
	return nil
}
