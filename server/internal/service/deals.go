package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The Royal Store's daily deals: four slots, as the painting has them -- a gift
// box, free; energy potions; a Protection Charter; a frame -- each keeping its
// picture while what is in it rotates. A lord's four are picked the first time
// they look on a day, from a seed of their own and the day, and kept in
// app.player_deals until their next midnight: the same four however often they
// look, and a balance published at noon reshuffles nothing.
//
// A deal is bought with diamonds, sequenced like any other spend. The gift is
// claimed the same way, and the Steward claims it for a lord he serves.

// Deal slots, in the painting's order.
const (
	dealGift = iota
	dealPotions
	dealCharters
	dealCosmetic
	dealSlots
)

// Deal slot kinds, as the view names them.
const (
	DealFree     = "free"
	DealDiamonds = "diamonds"
	DealCosmetic = "cosmetic"
)

var ErrDealStale = errors.New("that deal has ended; the day's new deals are on the shelf")

// dealPick is one slot's content as the day fixed it.
type dealPick struct {
	Slot int    `json:"slot"`
	ID   string `json:"id"`
	// The price that day, in diamonds: 0 for the gift.
	Diamonds int64 `json:"diamonds"`
	// The cosmetic slot's own price at the shop, for the plate to say what it saves.
	Was int64 `json:"was,omitempty"`
}

// DealView is one slot as the lord sees it.
type DealView struct {
	Slot     int            `json:"slot"`
	Kind     string         `json:"kind"`
	ID       string         `json:"id"`
	Title    string         `json:"title"`
	Lines    []rewards.Line `json:"lines"`
	Diamonds int64          `json:"diamonds,omitempty"`
	Was      int64          `json:"was,omitempty"`
	Claimed  bool           `json:"claimed"`
	// The cosmetic slot's cosmetic, resolved for drawing.
	Cosmetic *CosmeticView `json:"cosmetic,omitempty"`
}

// DealsView is the day's four.
type DealsView struct {
	Day string `json:"day"`
	// Seconds to the lord's next midnight, when the four are replaced.
	ResetsIn int64      `json:"resets_in"`
	Slots    []DealView `json:"slots"`
}

// DealClaim is what claiming or buying a deal answers: what it gave, the day's
// four as they now stand, and the confirmed snapshot.
type DealClaim struct {
	Lines    []rewards.Line `json:"lines"`
	Deals    DealsView      `json:"deals"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// pickDeals chooses a lord's four for a day. Pure: the same lord, day and
// catalogue always give the same four, and nothing but the seed decides them.
// `owned` is the cosmetics the lord holds; the frame slot offers one they do
// not, and stays empty (no id) when they own every one -- it never sells
// something its painted frame does not show.
func pickDeals(cfg *gameconfig.Bundle, secret []byte, playerID uuid.UUID, day time.Time,
	owned map[string]*time.Time) []dealPick {
	d := cfg.Commerce.Deals
	rng := game.SeedForString(secret, "deals:"+playerID.String(), uint64(day.Unix()))
	weighted := func(goods []gameconfig.DealGood) gameconfig.DealGood {
		total := 0
		for _, g := range goods {
			total += g.Weight
		}
		roll := rng.IntN(total)
		for _, g := range goods {
			if roll < g.Weight {
				return g
			}
			roll -= g.Weight
		}
		return goods[len(goods)-1]
	}
	gift := weighted(d.Gift)
	potions := weighted(d.Potions)
	charters := weighted(d.Charters)
	out := []dealPick{
		{Slot: dealGift, ID: gift.ID},
		{Slot: dealPotions, ID: potions.ID, Diamonds: potions.Diamonds},
		{Slot: dealCharters, ID: charters.ID, Diamonds: charters.Diamonds},
	}
	var shelf []*gameconfig.Cosmetic
	for i := range cfg.Cosmetics.Items {
		c := &cfg.Cosmetics.Items[i]
		if c.ShopDiamonds <= 0 || c.DefaultOwned {
			continue
		}
		if _, has := owned[c.ID]; has {
			continue
		}
		shelf = append(shelf, c)
	}
	if len(shelf) == 0 {
		return append(out, dealPick{Slot: dealCosmetic})
	}
	c := shelf[rng.IntN(len(shelf))]
	price := c.ShopDiamonds - c.ShopDiamonds*d.CosmeticOffBP/10000
	return append(out, dealPick{Slot: dealCosmetic, ID: c.ID, Diamonds: price, Was: c.ShopDiamonds})
}

// dealGood finds a pick's goods in the catalogue: the gift pool for slot 0, the
// potion and charter pools for the rest.
func dealGood(cfg *gameconfig.Bundle, id string) *gameconfig.DealGood {
	d := cfg.Commerce.Deals
	for _, pool := range [][]gameconfig.DealGood{d.Gift, d.Potions, d.Charters} {
		for i := range pool {
			if pool[i].ID == id {
				return &pool[i]
			}
		}
	}
	return nil
}

// todaysDeals returns the lord's row for today, picking and writing it the
// first time they look.
func (d Deps) todaysDeals(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (sqlcdb.AppPlayerDeal, []dealPick, error) {
	now := d.Now()
	today := localDay(now, p.ResetOffsetMinutes)
	row, err := q.GetDeals(ctx, p.ID)
	if err == nil && row.Day.Valid && row.Day.Time.Equal(today) {
		var picks []dealPick
		if jerr := json.Unmarshal(row.Slots, &picks); jerr == nil && len(picks) == dealSlots {
			return row, picks, nil
		}
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return row, nil, fmt.Errorf("deals: %w", err)
	}
	owned, err := d.owned(ctx, q, p.ID, now)
	if err != nil {
		return row, nil, err
	}
	picks := pickDeals(d.Config, d.ShopSecret, p.ID, today, owned)
	raw, _ := json.Marshal(picks)
	row, err = q.PutDeals(ctx, sqlcdb.PutDealsParams{PlayerID: p.ID, Day: dateOf(today), Slots: raw})
	if errors.Is(err, pgx.ErrNoRows) {
		// Someone looked first, a moment ago: theirs stands.
		if row, err = q.GetDeals(ctx, p.ID); err != nil {
			return row, nil, fmt.Errorf("deals: %w", err)
		}
		if err := json.Unmarshal(row.Slots, &picks); err != nil {
			return row, nil, fmt.Errorf("deals: %w", err)
		}
		return row, picks, nil
	}
	if err != nil {
		return row, nil, fmt.Errorf("write deals: %w", err)
	}
	return row, picks, nil
}

// dealsView resolves the day's four for drawing.
func (d Deps) dealsView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (DealsView, error) {
	row, picks, err := d.todaysDeals(ctx, q, p)
	if err != nil {
		return DealsView{}, err
	}
	now := d.Now()
	today := localDay(now, p.ResetOffsetMinutes)
	next := today.Add(24*time.Hour - time.Duration(p.ResetOffsetMinutes)*time.Minute)
	out := DealsView{Day: today.Format("2006-01-02"), ResetsIn: int64(next.Sub(now) / time.Second), Slots: []DealView{}}
	if out.ResetsIn < 0 {
		out.ResetsIn = 0
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return out, err
	}
	var owned map[string]*time.Time
	for _, pk := range picks {
		v := DealView{Slot: pk.Slot, ID: pk.ID, Diamonds: pk.Diamonds, Lines: []rewards.Line{},
			Claimed: row.Claimed&(1<<pk.Slot) != 0}
		if g := dealGood(d.Config, pk.ID); g != nil {
			v.Kind, v.Title, v.Was = DealDiamonds, g.Title, g.Was
			if pk.Slot == dealGift {
				v.Kind = DealFree
			}
			v.Lines = rewards.Lines(d.Config, g.Grant, rewards.Resolve(d.Config, g.Grant, int(p.Level), eff.Bonuses))
		} else if c := d.Config.Cosmetic(pk.ID); c != nil {
			if owned == nil {
				if owned, err = d.owned(ctx, q, p.ID, now); err != nil {
					return out, err
				}
			}
			_, has := owned[c.ID]
			v.Kind, v.Title, v.Was = DealCosmetic, c.Name, pk.Was
			v.Cosmetic = &CosmeticView{ID: c.ID, Kind: c.Kind, Name: c.Name, Text: c.Text, Color: c.Color, Art: c.Art, Owned: has}
			line := rewards.Lines(d.Config, gameconfig.RewardBundle{Cosmetics: []string{c.ID}}, rewards.Resolve(d.Config,
				gameconfig.RewardBundle{Cosmetics: []string{c.ID}}, int(p.Level), eff.Bonuses))
			v.Lines = line
			// Bought elsewhere since the day began: nothing left to sell here.
			v.Claimed = v.Claimed || has
		} else {
			// A catalogue published since the morning no longer has it.
			continue
		}
		out.Slots = append(out.Slots, v)
	}
	return out, nil
}

// ClaimDeal takes one of the day's deals: the gift for nothing, the rest for
// their diamonds. Sequenced, like every other spend.
func (d Deps) ClaimDeal(ctx context.Context, playerID uuid.UUID, slot int, wantSeq int64) (*DealClaim, error) {
	if slot < 0 || slot >= dealSlots {
		return nil, ErrNotFound
	}
	var view DealsView
	var lines []rewards.Line
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
		if lines, err = d.claimDeal(ctx, q, &p, slot, false); err != nil {
			return err
		}
		if _, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: p.ID, ActionSeq: wantSeq}); err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		view, err = d.dealsView(ctx, q, p)
		return err
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	return &DealClaim{Lines: lines, Deals: view, Snapshot: snap}, err
}

// claimDeal takes one slot, inside the caller's transaction, and says what it
// gave. `giftOnly` is the Steward's: he claims what is free and never spends a
// lord's diamonds.
func (d Deps) claimDeal(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, slot int, giftOnly bool) ([]rewards.Line, error) {
	row, picks, err := d.todaysDeals(ctx, q, *p)
	if err != nil {
		return nil, err
	}
	if row.Claimed&(1<<slot) != 0 {
		return nil, ErrNothingToClaim
	}
	var pk *dealPick
	for i := range picks {
		if picks[i].Slot == slot {
			pk = &picks[i]
		}
	}
	if pk == nil {
		return nil, ErrDealStale
	}
	if giftOnly && pk.Diamonds > 0 {
		return nil, ErrNothingToClaim
	}
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	ref := fmt.Sprintf("deal:%s:%d", today.Format("2006-01-02"), slot)

	// The slot first: a double tap loses the race here, before anything moves.
	if _, err := q.ClaimDealSlot(ctx, sqlcdb.ClaimDealSlotParams{PlayerID: p.ID, Day: dateOf(today), Bit: 1 << slot}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNothingToClaim
		}
		return nil, fmt.Errorf("claim deal: %w", err)
	}

	good := dealGood(d.Config, pk.ID)
	cos := d.Config.Cosmetic(pk.ID)
	if good == nil && cos == nil {
		return nil, ErrDealStale
	}
	if cos != nil {
		owned, err := d.owned(ctx, q, p.ID, d.Now())
		if err != nil {
			return nil, err
		}
		if _, has := owned[cos.ID]; has {
			return nil, ErrCosmeticOwned
		}
	}
	if pk.Diamonds > 0 {
		after, err := q.SpendDiamonds(ctx, sqlcdb.SpendDiamondsParams{ID: p.ID, Amount: pk.Diamonds})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotEnoughDiamonds
		}
		if err != nil {
			return nil, fmt.Errorf("spend diamonds: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, *p, after, -pk.Diamonds, ledger.Deal, ref); err != nil {
			return nil, err
		}
		*p = after
	}
	if cos != nil {
		if _, err := q.InsertCosmetic(ctx, sqlcdb.InsertCosmeticParams{
			PlayerID: p.ID, CosmeticID: cos.ID, Source: "deal", SourceRef: &ref,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("grant cosmetic: %w", err)
		}
		// A cosmetic resolves to itself: no bucket touches it.
		b := gameconfig.RewardBundle{Cosmetics: []string{cos.ID}}
		return rewards.Lines(d.Config, b, rewards.Resolved{}), nil
	}
	// Goods bought with diamonds keep the paid rules; the gift is free.
	src := GrantSource{Diamonds: ledger.DailyGift, Gold: "daily_gift", Ref: ref, ItemFrom: "reward",
		Paid: slot != dealGift}
	g, err := d.grantBundle(ctx, q, p, good.Grant, src)
	if err != nil {
		return nil, err
	}
	return g.Lines, nil
}

// giftWaiting reports whether today's free gift is still in its box, for the
// store's badge. A lord who has not looked today has one waiting.
func (d Deps) giftWaiting(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) bool {
	row, err := q.GetDeals(ctx, p.ID)
	if err != nil {
		return errors.Is(err, pgx.ErrNoRows)
	}
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	if !row.Day.Valid || !row.Day.Time.Equal(today) {
		return true
	}
	return row.Claimed&(1<<dealGift) == 0
}
