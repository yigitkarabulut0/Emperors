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
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
)

// AutoEquipResult reports what changed.
type AutoEquipResult struct {
	Equipped int       `json:"equipped"`
	Army     *ArmyView `json:"army"`
}

// AutoEquip puts the best gear you own on the units you asked for.
//
// "Best" is item Power, which already folds attack, defence and a weighted share
// of speed into one number -- the same figure the item cards compare against, so
// the button agrees with what the player can see.
//
// WHICH unit gets which item does not change Might: Might is 2*sqrt(sum ATK *
// sum EHP) and both are plain sums, so an item is worth the same on anyone. The
// strongest unit is served first anyway, because the front line takes the damage
// and keeping it standing is worth something the Might figure does not show.
//
// Runs on the server rather than as a loop of equip calls from the client: it is
// a rule about what "best" means, it has to be one transaction, and a client
// loop would be three round trips per unit racing the action sequence.
func (d Deps) AutoEquip(ctx context.Context, playerID uuid.UUID, scope string, wantSeq int64) (*AutoEquipResult, error) {
	switch scope {
	case "hero", "army":
	default:
		return nil, ErrNotFound
	}

	var equipped int
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

		owned, err := q.ListPlayerItems(ctx, playerID)
		if err != nil {
			return fmt.Errorf("list items: %w", err)
		}
		soldiers, err := q.ListSoldiers(ctx, playerID)
		if err != nil {
			return fmt.Errorf("list soldiers: %w", err)
		}

		// Holders in the order they get first pick.
		type holder struct {
			soldierID *uuid.UUID // nil means the hero
			strength  int64
		}
		// The hero is always first, ahead of any soldier. Not for the maths --
		// Might is 2*sqrt(sum ATK * sum EHP) and both are plain sums, so an item
		// is worth the same on anyone -- but because it is YOUR character, it is
		// the one on every screen, and it is the one that cannot be dismissed. An
		// "equip the best" button that leaves you holding nothing has not done
		// what it said.
		var mercs []holder
		for i := range soldiers {
			s := soldiers[i]
			mercs = append(mercs, holder{&s.ID, int64(d.Config.TierRank(s.Tier))*1000 + int64(s.Level)})
		}
		sort.SliceStable(mercs, func(i, j int) bool { return mercs[i].strength > mercs[j].strength })

		holders := []holder{{nil, 0}}
		if scope == "army" {
			holders = append(holders, mercs...)
		}

		power := func(r sqlcdb.AppPlayerItem) int64 {
			return items.Instance{
				Slot: r.Slot, Tier: r.Tier,
				Attack: r.Attack, Defense: r.Defense, Speed: r.Speed,
			}.Power(d.Config)
		}

		for _, slot := range []string{"weapon", "armor", "horse"} {
			// Every item that fits this slot, best first. Items worn by a unit
			// OUTSIDE the chosen scope are left alone: auto-equipping the hero
			// must not quietly strip a soldier.
			var pool []sqlcdb.AppPlayerItem
			for _, it := range owned {
				if it.Slot != slot {
					continue
				}
				if scope == "hero" && it.EquippedSoldierID != nil {
					continue
				}
				pool = append(pool, it)
			}
			sort.SliceStable(pool, func(i, j int) bool { return power(pool[i]) > power(pool[j]) })

			for hi, h := range holders {
				if hi >= len(pool) {
					break // ran out of gear for this slot
				}
				want := pool[hi]

				// Already worn by the right holder? Nothing to do.
				if h.soldierID == nil && want.EquippedOnHero {
					continue
				}
				if h.soldierID != nil && want.EquippedSoldierID != nil && *want.EquippedSoldierID == *h.soldierID {
					continue
				}

				// Free both ends before writing: the item's previous owner, and
				// whatever this holder is wearing in this slot. The partial unique
				// index must never see two items in one slot, even transiently.
				if err := q.ReleaseItem(ctx, sqlcdb.ReleaseItemParams{ID: want.ID, PlayerID: playerID}); err != nil {
					return fmt.Errorf("release: %w", err)
				}
				if h.soldierID == nil {
					if err := q.UnequipHeroSlot(ctx, sqlcdb.UnequipHeroSlotParams{
						PlayerID: playerID, Slot: slot,
					}); err != nil {
						return fmt.Errorf("clear hero slot: %w", err)
					}
					if err := q.SetHeroEquipped(ctx, sqlcdb.SetHeroEquippedParams{
						ID: want.ID, PlayerID: playerID, EquippedOnHero: true,
					}); err != nil {
						return fmt.Errorf("equip hero: %w", err)
					}
				} else {
					if err := q.UnequipSoldierSlot(ctx, sqlcdb.UnequipSoldierSlotParams{
						PlayerID: playerID, EquippedSoldierID: h.soldierID, Slot: slot,
					}); err != nil {
						return fmt.Errorf("clear soldier slot: %w", err)
					}
					if err := q.SetSoldierEquipped(ctx, sqlcdb.SetSoldierEquippedParams{
						ID: want.ID, PlayerID: playerID, EquippedSoldierID: h.soldierID,
					}); err != nil {
						return fmt.Errorf("equip soldier: %w", err)
					}
				}
				equipped++
			}
		}

		if _, err := q.BumpActionSeq(ctx, sqlcdb.BumpActionSeqParams{ID: playerID, ActionSeq: wantSeq}); err != nil {
			return fmt.Errorf("bump seq: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res := &AutoEquipResult{Equipped: equipped}
	res.Army, err = d.GetArmy(ctx, playerID)
	return res, err
}
