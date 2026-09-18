package service

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// Splendour: portrait frames, titles, name colours and crests. How a lord
// looks to everyone else, never how they fight. The catalog is the balance's;
// the client keeps none of its own, so every view here carries the art key
// and the colour already resolved.
var (
	ErrCosmeticLocked  = errors.New("that is not yours to wear")
	ErrCosmeticNotSold = errors.New("that is not for sale")
	ErrCosmeticOwned   = errors.New("you already own that")
)

// CosmeticView is one cosmetic as a lord sees it.
type CosmeticView struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Name  string `json:"name"`
	Text  string `json:"text,omitempty"`
	Color string `json:"color,omitempty"`
	Art   string `json:"art,omitempty"`
	Owned bool   `json:"owned"`
	Worn  bool   `json:"worn"`
	// Its price in the Splendour shop; 0 when it is not sold.
	ShopDiamonds int64 `json:"shop_diamonds,omitempty"`
	// Where it comes from, for one that is not owned.
	Source string `json:"source,omitempty"`
	// Seconds left on one held for a time (a patron's frame); 0 is for good.
	ExpiresIn int64 `json:"expires_in,omitempty"`
}

// Worn is what a lord wears, one of each kind, resolved for drawing. Sent with
// every view that shows a lord, so the same lord looks the same everywhere.
type Worn struct {
	Frame string `json:"frame,omitempty"` // art key; the client draws <art>_square or <art>_ring
	Title string `json:"title,omitempty"` // the words under the name
	Color string `json:"color,omitempty"` // #rrggbb for the name
	Crest string `json:"crest,omitempty"` // art key
}

// WardrobeView is the whole catalog for one lord.
type WardrobeView struct {
	Items    []CosmeticView `json:"items"`
	Worn     Worn           `json:"worn"`
	Diamonds int64          `json:"diamonds"`
}

// owned is what a lord holds now: default crests, and rows not yet expired.
func (d Deps) owned(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, now time.Time) (map[string]*time.Time, error) {
	out := map[string]*time.Time{}
	for _, c := range d.Config.Cosmetics.Items {
		if c.DefaultOwned {
			out[c.ID] = nil
		}
	}
	rows, err := q.ListCosmetics(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("cosmetics: %w", err)
	}
	for _, r := range rows {
		if r.ExpiresAt != nil && !r.ExpiresAt.After(now) {
			continue
		}
		out[r.CosmeticID] = r.ExpiresAt
	}
	return out, nil
}

// wornOf resolves what a lord wears. An id they no longer hold -- a patron's
// frame after the patronage ended -- resolves to nothing, so nobody wears what
// they have lost.
func (d Deps) wornOf(p sqlcdb.AppPlayer, owned map[string]*time.Time) Worn {
	var w Worn
	pick := func(id *string, kind string) *gameconfig.Cosmetic {
		if id == nil {
			return nil
		}
		c := d.Config.Cosmetic(*id)
		if c == nil || c.Kind != kind {
			return nil
		}
		if owned != nil {
			if _, ok := owned[c.ID]; !ok {
				return nil
			}
		}
		return c
	}
	if c := pick(p.CosFrame, gameconfig.CosmeticFrame); c != nil {
		w.Frame = c.Art
	}
	if c := pick(p.CosTitle, gameconfig.CosmeticTitle); c != nil {
		w.Title = c.Text
	}
	if c := pick(p.CosColor, gameconfig.CosmeticNameColor); c != nil {
		w.Color = c.Color
	}
	if c := pick(p.CosCrest, gameconfig.CosmeticCrest); c != nil {
		w.Crest = c.Art
	}
	return w
}

// GetWardrobe lists every cosmetic, what the lord owns and wears first.
func (d Deps) GetWardrobe(ctx context.Context, playerID uuid.UUID) (*WardrobeView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load player: %w", err)
	}
	return d.wardrobe(ctx, q, p)
}

func (d Deps) wardrobe(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*WardrobeView, error) {
	now := d.Now()
	own, err := d.owned(ctx, q, p.ID, now)
	if err != nil {
		return nil, err
	}
	worn := map[string]bool{}
	for _, id := range []*string{p.CosFrame, p.CosTitle, p.CosColor, p.CosCrest} {
		if id != nil {
			worn[*id] = true
		}
	}
	v := &WardrobeView{Items: []CosmeticView{}, Worn: d.wornOf(p, own), Diamonds: p.Diamonds}
	for _, c := range d.Config.Cosmetics.Items {
		exp, has := own[c.ID]
		cv := CosmeticView{ID: c.ID, Kind: c.Kind, Name: c.Name, Text: c.Text, Color: c.Color, Art: c.Art,
			Owned: has, Worn: has && worn[c.ID]}
		if !has {
			cv.ShopDiamonds, cv.Source = c.ShopDiamonds, c.SourceHint
		}
		if has && exp != nil {
			cv.ExpiresIn = int64(exp.Sub(now) / time.Second)
		}
		v.Items = append(v.Items, cv)
	}
	sort.SliceStable(v.Items, func(i, k int) bool {
		a, b := v.Items[i], v.Items[k]
		if a.Kind != b.Kind {
			return kindOrder[a.Kind] < kindOrder[b.Kind]
		}
		return a.Owned && !b.Owned
	})
	return v, nil
}

var kindOrder = map[string]int{gameconfig.CosmeticFrame: 0, gameconfig.CosmeticTitle: 1,
	gameconfig.CosmeticNameColor: 2, gameconfig.CosmeticCrest: 3}

// WearCosmetic puts on a cosmetic the lord owns, or takes a kind off (empty id).
// Not sequenced: what a lord wears touches nothing a queued collect reads.
func (d Deps) WearCosmetic(ctx context.Context, playerID uuid.UUID, kind, id string) (*WardrobeView, error) {
	if _, ok := kindOrder[kind]; !ok {
		return nil, ErrNotFound
	}
	var out *WardrobeView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		var target *string
		if id != "" {
			c := d.Config.Cosmetic(id)
			if c == nil || c.Kind != kind {
				return ErrNotFound
			}
			own, err := d.owned(ctx, q, p.ID, d.Now())
			if err != nil {
				return err
			}
			if _, ok := own[id]; !ok {
				return ErrCosmeticLocked
			}
			target = &id
		}
		after, err := q.WearCosmetic(ctx, sqlcdb.WearCosmeticParams{ID: p.ID, Kind: kind, CosmeticID: target})
		if err != nil {
			return fmt.Errorf("wear: %w", err)
		}
		out, err = d.wardrobe(ctx, q, after)
		return err
	})
	return out, err
}

// BuyCosmetic buys a cosmetic from the Splendour shop with diamonds, and wears it.
func (d Deps) BuyCosmetic(ctx context.Context, playerID uuid.UUID, id string, wantSeq int64) (*WardrobeView, error) {
	c := d.Config.Cosmetic(id)
	if c == nil {
		return nil, ErrNotFound
	}
	if c.ShopDiamonds <= 0 || c.DefaultOwned {
		return nil, ErrCosmeticNotSold
	}
	var out *WardrobeView
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		if err := checkSeq(p, wantSeq); err != nil {
			return err
		}
		own, err := d.owned(ctx, q, p.ID, d.Now())
		if err != nil {
			return err
		}
		if _, ok := own[id]; ok {
			return ErrCosmeticOwned
		}
		after, err := q.SpendDiamonds(ctx, sqlcdb.SpendDiamondsParams{ID: p.ID, Amount: c.ShopDiamonds})
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotEnoughDiamonds
		}
		if err != nil {
			return fmt.Errorf("spend diamonds: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, -c.ShopDiamonds, ledger.Cosmetic, id); err != nil {
			return err
		}
		if _, err := q.InsertCosmetic(ctx, sqlcdb.InsertCosmeticParams{
			PlayerID: p.ID, CosmeticID: id, Source: "shop",
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("grant cosmetic: %w", err)
		}
		if after, err = q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: p.ID, ActionSeq: wantSeq}); err != nil {
			return fmt.Errorf("sequence: %w", err)
		}
		if after, err = q.WearCosmetic(ctx, sqlcdb.WearCosmeticParams{ID: p.ID, Kind: c.Kind, CosmeticID: &id}); err != nil {
			return fmt.Errorf("wear: %w", err)
		}
		out, err = d.wardrobe(ctx, q, after)
		return err
	})
	return out, err
}
