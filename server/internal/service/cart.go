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
	"github.com/yigitkarabulut0/emperors/server/internal/game/cart"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The Tax Cart (retention.cart): every four hours a cart comes to the lord's
// gate with the crown's share of the road, three can wait, and each opens to a
// prize drawn from the published odds. A cart's prize is fixed by the lord and
// the cart's number before it is opened, so it cannot be drawn again; and it
// is free only -- a cart writ (the `cart` token) is never sold.

var (
	// ErrCartEmpty is opening with no cart waiting and no writ held.
	ErrCartEmpty = errors.New("no cart is waiting")
	// ErrCartLocked is opening below the cart's level.
	ErrCartLocked = errors.New("the tax cart comes to lords of a higher level")
)

// CartSnap is the Tax Cart on the snapshot: enough for the Court's card and a
// badge.
type CartSnap struct {
	Unlocked    bool  `json:"unlocked"`
	UnlockLevel int   `json:"unlock_level"`
	Stock       int   `json:"stock"`
	Cap         int   `json:"cap"`
	Tokens      int64 `json:"tokens"`
	NextIn      int64 `json:"next_in"`
	Interval    int64 `json:"interval"`
}

// CartOdds is one row of the published odds, with what it would pay now.
type CartOdds struct {
	ID    string         `json:"id"`
	Name  string         `json:"name"`
	BP    int64          `json:"bp"`
	Lines []rewards.Line `json:"lines"`
}

// CartView is the CHESTS page.
type CartView struct {
	CartSnap
	CanOpen bool       `json:"can_open"`
	Opened  int        `json:"opened"`
	Odds    []CartOdds `json:"odds"`
}

// CartOpen is one cart opened.
type CartOpen struct {
	Prize    string         `json:"prize"`
	Name     string         `json:"name"`
	Lines    []rewards.Line `json:"lines"`
	Cart     *CartView      `json:"cart"`
	Snapshot *Snapshot      `json:"snapshot"`
}

func (d Deps) cartInterval() time.Duration {
	return time.Duration(d.Config.Retention.Cart.IntervalSeconds) * time.Second
}

// settledYard is the lord's yard as it stands at now. Clocks are kept to the
// microsecond, as the database keeps them, so a yard settled in memory and one
// read back agree.
func (d Deps) settledYard(p sqlcdb.AppPlayer, now time.Time) cart.Yard {
	c := d.Config.Retention.Cart
	return cart.Settle(cart.Yard{Stock: int(p.CartStock), At: p.CartAt}, c.Cap, d.cartInterval(),
		now.Truncate(time.Microsecond))
}

func (d Deps) cartSnap(p sqlcdb.AppPlayer, writs int64, now time.Time) CartSnap {
	c := d.Config.Retention.Cart
	y := d.settledYard(p, now)
	return CartSnap{
		Unlocked: int(p.Level) >= c.UnlockLevel, UnlockLevel: c.UnlockLevel,
		Stock: y.Stock, Cap: c.Cap, Tokens: writs,
		NextIn:   ceilSeconds(cart.NextIn(y, c.Cap, d.cartInterval(), now)),
		Interval: c.IntervalSeconds,
	}
}

// ceilSeconds is a wait in whole seconds, rounded up: a countdown that reads 0
// while something is still a moment away would be early.
func ceilSeconds(w time.Duration) int64 {
	if w <= 0 {
		return 0
	}
	return int64((w + time.Second - 1) / time.Second)
}

// GetCart reports the Tax Cart and its odds.
func (d Deps) GetCart(ctx context.Context, playerID uuid.UUID) (*CartView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("cart: %w", err)
	}
	return d.cartView(ctx, q, p)
}

func (d Deps) cartView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*CartView, error) {
	held, err := tokenCounts(ctx, q, p.ID)
	if err != nil {
		return nil, err
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	snap := d.cartSnap(p, held["cart"], d.Now())
	v := &CartView{CartSnap: snap, Opened: int(p.CartsOpened),
		CanOpen: snap.Unlocked && (snap.Stock > 0 || snap.Tokens > 0)}
	bonuses := rewards.PermanentOnly(eff.Bonuses)
	for _, o := range d.Config.Retention.Cart.Odds {
		v.Odds = append(v.Odds, CartOdds{ID: o.ID, Name: o.Name, BP: o.BP,
			Lines: rewards.Lines(d.Config, o.Grant, rewards.Resolve(d.Config, o.Grant, int(p.Level), bonuses))})
	}
	return v, nil
}

// OpenCart opens one cart: a waiting one first, else a writ.
func (d Deps) OpenCart(ctx context.Context, playerID uuid.UUID) (*CartOpen, error) {
	var res CartOpen
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		prize, lines, err := d.openOneCart(ctx, q, &p, true, d.Now())
		if err != nil {
			return err
		}
		res.Prize, res.Name, res.Lines = prize.ID, prize.Name, lines
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.CartsOpened: 1})
		return nil
	})
	if err != nil {
		return nil, err
	}
	if res.Cart, err = d.GetCart(ctx, playerID); err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// openOneCart takes a cart from the settled yard (or, with writs, a writ when
// the yard is empty), draws its prize and pays it. The caller holds the lock.
// A prize that cannot be paid -- gear for a full bag -- fails the whole
// opening, so the cart waits, prize and all.
func (d Deps) openOneCart(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, writs bool,
	now time.Time) (gameconfig.CartPrize, []rewards.Line, error) {
	c := d.Config.Retention.Cart
	if int(p.Level) < c.UnlockLevel {
		return gameconfig.CartPrize{}, nil, ErrCartLocked
	}
	if len(c.Odds) == 0 {
		return gameconfig.CartPrize{}, nil, ErrCartEmpty
	}
	now = now.Truncate(time.Microsecond)
	y := d.settledYard(*p, now)
	taken, ok := cart.Take(y, c.Cap, now)
	if !ok {
		if !writs {
			return gameconfig.CartPrize{}, nil, ErrCartEmpty
		}
		if _, err := q.SpendToken(ctx, sqlcdb.SpendTokenParams{PlayerID: p.ID, Token: "cart", Qty: 1}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return gameconfig.CartPrize{}, nil, ErrCartEmpty
			}
			return gameconfig.CartPrize{}, nil, fmt.Errorf("use a writ: %w", err)
		}
		taken = y
	}

	// The Nth cart's prize, whatever the lord does before opening it.
	n := uint64(p.CartsOpened) + 1
	prize := c.Odds[cart.Draw(game.SeedForString(d.ShopSecret, p.ID.String(), n, 0xCA27), c.Odds)]

	after, err := q.SetCartYard(ctx, sqlcdb.SetCartYardParams{
		ID: p.ID, Stock: int16(taken.Stock), At: taken.At, Opened: 1,
	})
	if err != nil {
		return prize, nil, fmt.Errorf("open a cart: %w", err)
	}
	*p = after
	g, err := d.grantBundle(ctx, q, p, prize.Grant, GrantSource{
		Diamonds: ledger.Cart, Gold: "cart", Ref: fmt.Sprintf("cart:%d", n), ItemFrom: "chest",
	})
	if err != nil {
		return prize, nil, err
	}
	return prize, g.Lines, nil
}
