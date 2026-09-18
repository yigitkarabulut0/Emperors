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
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

// THE FORGE -- the inventory's other verb (forge.json).
//
// Three pieces of one slot and one rank, and gold worth a share of what the
// rank above costs, make one piece of that rank: the best MARK of the three, a
// fresh quality roll and a fresh chance at a masterwork, at odds the screen
// publishes.
//
// The fee is what stops it being a mint. gameconfig's validator proves the fee
// is a larger share of the next rank's price than selling pays back, so the
// round trip always loses -- at every rung and in every slot -- and
// items/forge_test.go proves it again on real pieces.

var (
	ErrForgeLocked = errors.New("the forge opens later")
	ErrForgePieces = errors.New("the forge takes three pieces of one slot and one rank")
	ErrForgeTop    = errors.New("there is nothing above that rank to forge into")
	ErrForgeWorn   = errors.New("take the piece off before feeding it to the forge")
)

// ForgeView is what the anvil promises before the tap.
type ForgeView struct {
	Unlocked    bool `json:"unlocked"`
	UnlockLevel int  `json:"unlock_level"`
	Pieces      int  `json:"pieces"`
	// The odds, published: the quality band and the masterwork chance.
	QualityMin         int64 `json:"quality_min_pct"`
	QualityMax         int64 `json:"quality_max_pct"`
	MasterworkChanceBP int64 `json:"masterwork_chance_bp"`
	// The ranks the anvil will take.
	Tiers []string `json:"tiers"`
}

// ForgeQuote is one particular three pieces: what they make and what it costs.
type ForgeQuote struct {
	Slot     string `json:"slot"`
	Tier     string `json:"tier"`
	NextTier string `json:"next_tier"`
	Ilvl     int64  `json:"ilvl"`
	Fee      int64  `json:"fee"`
}

// ForgeResult is what came off the anvil.
type ForgeResult struct {
	Item     ItemView   `json:"item"`
	Fee      int64      `json:"fee"`
	Quote    ForgeQuote `json:"quote"`
	Snapshot *Snapshot  `json:"snapshot"`
}

// forgeView is the anvil's own card, which the inventory carries.
func (d Deps) forgeView(p sqlcdb.AppPlayer) ForgeView {
	f := d.Config.Forge
	at := d.Config.SectionLevel(f.Section)
	return ForgeView{
		Unlocked: int(p.Level) >= at, UnlockLevel: at, Pieces: f.Pieces,
		QualityMin: f.Quality.MinPct, QualityMax: f.Quality.MaxPct,
		MasterworkChanceBP: f.MasterworkChanceBP,
		Tiers:              append([]string{}, f.Tiers...),
	}
}

// Forge turns three pieces into one of the rank above.
//
// Sequenced: it spends gold, and the client's queued collects are counting on
// the order.
func (d Deps) Forge(ctx context.Context, playerID uuid.UUID, itemIDs []uuid.UUID,
	wantSeq int64) (*ForgeResult, error) {

	res := &ForgeResult{}
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
		if int(p.Level) < d.Config.SectionLevel(d.Config.Forge.Section) {
			return ErrForgeLocked
		}
		if len(itemIDs) != d.Config.Forge.Pieces {
			return ErrForgePieces
		}

		// Lock the three in a settled order, so two lords feeding overlapping
		// piles -- or one lord tapping twice -- cannot deadlock.
		ordered := append([]uuid.UUID{}, itemIDs...)
		sortUUIDs(ordered)
		seen := make(map[uuid.UUID]bool, len(ordered))
		pieces := make([]items.Instance, 0, len(ordered))
		for _, id := range ordered {
			if seen[id] {
				return ErrForgePieces // the same piece named twice is not three pieces
			}
			seen[id] = true
			it, err := q.LockPlayerItem(ctx, sqlcdb.LockPlayerItemParams{ID: id, PlayerID: playerID})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotFound
				}
				return fmt.Errorf("lock item: %w", err)
			}
			if it.EquippedOnHero || it.EquippedSoldierID != nil {
				return ErrForgeWorn
			}
			pieces = append(pieces, items.Instance{
				DefID: it.DefID, Slot: it.Slot, Tier: it.Tier, Ilvl: int64(it.Ilvl),
				QualityPct: int64(it.QualityPct), Masterwork: it.Masterwork,
				Attack: it.Attack, Defense: it.Defense, Speed: it.Speed,
			})
		}
		if err := items.CanForge(d.Config, pieces); err != nil {
			switch {
			case errors.Is(err, items.ErrForgeTier):
				return ErrForgeTop
			default:
				return ErrForgePieces
			}
		}

		slot, tier := pieces[0].Slot, pieces[0].Tier
		ilvl := items.ForgeILvl(pieces)
		fee := items.ForgeFee(d.Config, slot, tier, ilvl)
		res.Quote = ForgeQuote{
			Slot: slot, Tier: tier, NextTier: items.NextTier(d.Config, tier), Ilvl: ilvl, Fee: fee,
		}

		eff, err := d.loadEffects(ctx, q, p)
		if err != nil {
			return err
		}
		// Seeded from the pieces themselves, so a retry of the same tap rolls
		// the same piece and the anvil cannot be re-rolled by a dropped
		// connection.
		rng := game.SeedForString(d.ShopSecret, "forge:"+ordered[0].String(),
			uint64(ilvl), uint64(len(pieces)))
		made, err := items.Forge(d.Config, rng, pieces, eff.LuckBP)
		if err != nil {
			return ErrForgePieces
		}

		after, err := q.SpendGold(ctx, sqlcdb.SpendGoldParams{
			ID: playerID, Gold: fee, ActionSeq: wantSeq,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotEnoughGold
			}
			return fmt.Errorf("forge fee: %w", err)
		}
		if err := q.RecordGold(ctx, sqlcdb.RecordGoldParams{
			PlayerID: playerID, Delta: -fee, BalanceAfter: after.Gold,
			Reason: "forge", RefID: strPtr(ordered[0].String()),
		}); err != nil {
			return fmt.Errorf("gold ledger: %w", err)
		}

		for _, id := range ordered {
			if err := q.DeletePlayerItem(ctx, sqlcdb.DeletePlayerItemParams{
				ID: id, PlayerID: playerID,
			}); err != nil {
				return fmt.Errorf("consume piece: %w", err)
			}
		}
		row, err := q.InsertPlayerItem(ctx, sqlcdb.InsertPlayerItemParams{
			PlayerID: playerID, DefID: made.DefID, Slot: made.Slot, Tier: made.Tier,
			Ilvl: int32(made.Ilvl), QualityPct: int32(made.QualityPct), Masterwork: made.Masterwork,
			Attack: made.Attack, Defense: made.Defense, Speed: made.Speed,
			AcquiredFrom: "forge", RolledConfigVersion: int32(d.Config.Version),
		})
		if err != nil {
			return fmt.Errorf("insert forged: %w", err)
		}
		res.Item, res.Fee = d.itemView(row), fee
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.Forges: 1})
		return nil
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	res.Snapshot = snap
	return res, err
}

// sortUUIDs orders ids so every caller locks the same rows in the same order.
func sortUUIDs(ids []uuid.UUID) {
	for i := 1; i < len(ids); i++ {
		for j := i; j > 0 && compareUUID(ids[j-1], ids[j]) > 0; j-- {
			ids[j-1], ids[j] = ids[j], ids[j-1]
		}
	}
}

func compareUUID(a, b uuid.UUID) int {
	for i := range a {
		switch {
		case a[i] < b[i]:
			return -1
		case a[i] > b[i]:
			return 1
		}
	}
	return 0
}
