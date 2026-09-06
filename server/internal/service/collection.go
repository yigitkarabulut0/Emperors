package service

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// ErrAlreadyCollected is a donation of something already on the wall.
var ErrAlreadyCollected = errors.New("that one is already in your collection")

// CollectionEntry is one design, held or not.
type CollectionEntry struct {
	DefID string `json:"def_id"`
	Name  string `json:"name"`
	Slot  string `json:"slot"`
	Tier  string `json:"tier"`
	Held  bool   `json:"held"`
}

// CollectionSet is one slot at one tier: three designs, and whether all three
// are in.
type CollectionSet struct {
	Slot     string            `json:"slot"`
	Tier     string            `json:"tier"`
	Complete bool              `json:"complete"`
	Entries  []CollectionEntry `json:"entries"`
}

// CollectionView is the whole wall.
type CollectionView struct {
	Sets   []CollectionSet `json:"sets"`
	Held   int             `json:"held"`
	Total  int             `json:"total"`
	LuckBP int64           `json:"luck_bp"`
}

// collectionLuck is what a collection is worth, in luck basis points.
//
// Pure, and shared by the view and by loadEffects, so what the screen promises
// and what the rolls actually use cannot diverge.
func collectionLuck(cfg *gameconfig.Bundle, held map[string]bool) int64 {
	c := cfg.Items.Collection
	var bp int64

	// Per piece.
	sets := map[string][]gameconfig.ItemDef{}
	for _, d := range cfg.Items.Definitions {
		if held[d.ID] {
			bp += c.LuckBPPerPiece
		}
		key := d.Slot + "|" + d.Tier
		sets[key] = append(sets[key], d)
	}

	// And again for each complete slot-and-tier set, which is what makes the
	// third of a kind worth holding rather than selling.
	for _, defs := range sets {
		all := len(defs) > 0
		for _, d := range defs {
			if !held[d.ID] {
				all = false
				break
			}
		}
		if all {
			bp += c.LuckBPPerSet
		}
	}
	return bp
}

// GetCollection returns the wall.
func (d Deps) GetCollection(ctx context.Context, playerID uuid.UUID) (*CollectionView, error) {
	q := sqlcdb.New(d.Pool)
	ids, err := q.ListCollection(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("collection: %w", err)
	}
	held := make(map[string]bool, len(ids))
	for _, id := range ids {
		held[id] = true
	}

	byKey := map[string]*CollectionSet{}
	var order []string
	for _, def := range d.Config.Items.Definitions {
		key := def.Slot + "|" + def.Tier
		set, ok := byKey[key]
		if !ok {
			set = &CollectionSet{Slot: def.Slot, Tier: def.Tier, Complete: true}
			byKey[key] = set
			order = append(order, key)
		}
		set.Entries = append(set.Entries, CollectionEntry{
			DefID: def.ID, Name: def.Name, Slot: def.Slot, Tier: def.Tier,
			Held: held[def.ID],
		})
		if !held[def.ID] {
			set.Complete = false
		}
	}

	// Stable order: by slot, then up the tier ladder, so the wall reads the way
	// the ladder does rather than however the map iterated.
	sort.SliceStable(order, func(i, j int) bool {
		a, b := byKey[order[i]], byKey[order[j]]
		if a.Slot != b.Slot {
			return a.Slot < b.Slot
		}
		return d.Config.TierRank(a.Tier) < d.Config.TierRank(b.Tier)
	})

	out := &CollectionView{
		Total: len(d.Config.Items.Definitions), Held: len(held),
		LuckBP: collectionLuck(d.Config, held),
		Sets:   make([]CollectionSet, 0, len(order)),
	}
	for _, k := range order {
		out.Sets = append(out.Sets, *byKey[k])
	}
	return out, nil
}

// DonateToCollection puts an item on the wall and destroys it.
//
// Refuses BEFORE consuming anything if the design is already held: a donation
// that eats the item and gives nothing back is the kind of thing a player never
// forgives, and "you already have that one" is a sentence the server can say.
func (d Deps) DonateToCollection(ctx context.Context, playerID, itemID uuid.UUID, wantSeq int64) (*CollectionView, error) {
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

		it, err := q.LockPlayerItem(ctx, sqlcdb.LockPlayerItemParams{ID: itemID, PlayerID: playerID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock item: %w", err)
		}
		if it.EquippedOnHero || it.EquippedSoldierID != nil {
			return ErrItemEquipped
		}

		if _, err := q.DonateToCollection(ctx, sqlcdb.DonateToCollectionParams{
			PlayerID: playerID, DefID: it.DefID,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyCollected
			}
			return fmt.Errorf("donate: %w", err)
		}

		if err := q.DeletePlayerItem(ctx, sqlcdb.DeletePlayerItemParams{
			ID: itemID, PlayerID: playerID,
		}); err != nil {
			return fmt.Errorf("consume item: %w", err)
		}
		// The action counter still has to move, or the client's next request
		// arrives with a stale sequence.
		_, err = q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: playerID, ActionSeq: wantSeq})
		return err
	})
	if err != nil {
		return nil, err
	}
	return d.GetCollection(ctx, playerID)
}
