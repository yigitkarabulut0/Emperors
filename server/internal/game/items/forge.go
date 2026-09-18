package items

import (
	"errors"
	"math/rand/v2"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The forge (Wave 7).
//
// Three pieces of the same slot and rank, and gold worth a share of what the
// rank above sells for, make one piece of that rank. The gold is what stops it
// being a machine: gameconfig's validate_depth.go proves the fee is the larger
// share of the next rank's price than selling pays back, so forging and selling
// always loses -- at every rung, for every slot.
//
// What comes out keeps the best MARK of the three (a lord who feeds their best
// piece in gets the level they earned) and rolls its quality and its masterwork
// afresh, at odds the screen publishes.

var (
	// ErrForgeCount is the wrong number of pieces.
	ErrForgeCount = errors.New("the forge takes a fixed number of pieces")
	// ErrForgeMixed is pieces that are not all the same slot and rank.
	ErrForgeMixed = errors.New("the forge takes pieces of one slot and one rank")
	// ErrForgeTier is a rank the forge will not take.
	ErrForgeTier = errors.New("nothing above this rank to forge into")
)

// CanForge checks a pile of gear against the forge's rules.
func CanForge(cfg *gameconfig.Bundle, pieces []Instance) error {
	f := cfg.Forge
	if len(pieces) != f.Pieces {
		return ErrForgeCount
	}
	slot, tier := pieces[0].Slot, pieces[0].Tier
	for _, p := range pieces[1:] {
		if p.Slot != slot || p.Tier != tier {
			return ErrForgeMixed
		}
	}
	if !f.CanForge(tier) || NextTier(cfg, tier) == "" {
		return ErrForgeTier
	}
	return nil
}

// NextTier is the rank above this one, or empty at the top of the ladder.
func NextTier(cfg *gameconfig.Bundle, tier string) string {
	order := cfg.TierIDsAscending()
	i := cfg.TierRank(tier) - 1
	if i < 0 || i >= len(order)-1 {
		return ""
	}
	return order[i+1]
}

// ForgeILvl is the mark the forged piece comes out at: the best of the three,
// so a lord who feeds their best piece in keeps the level they earned.
func ForgeILvl(pieces []Instance) int64 {
	var ilvl int64
	for _, p := range pieces {
		if p.Ilvl > ilvl {
			ilvl = p.Ilvl
		}
	}
	return ilvl
}

// ForgeFee is the gold the anvil asks: a share of what the piece it is about to
// make would cost in the shop, undiscounted.
//
// Undiscounted on purpose. A Market talent or a kingdom's bazaar lowers what a
// shop charges; letting it lower the forge's fee as well would be the same
// percentage applied in two places, and the round trip the validator proves is a
// loss is proved against this price.
func ForgeFee(cfg *gameconfig.Bundle, slot, tier string, ilvl int64) int64 {
	next := NextTier(cfg, tier)
	if next == "" {
		return 0
	}
	fee := forgePrice(cfg, slot, next, ilvl) * cfg.Forge.FeeBPOfNextPrice / 10000
	if fee < 1 {
		return 1
	}
	return fee
}

// forgePrice is what a plain piece of that rank and mark costs in the shop: the
// yardstick the fee is a share of. A middling quality, so the fee does not move
// with a roll nobody has made yet.
func forgePrice(cfg *gameconfig.Bundle, slot, tier string, ilvl int64) int64 {
	q := cfg.Items.Quality
	mid := (q.MinPct + q.MaxPct) / 2
	atk, def, spd := Stat(cfg, slot, tier, ilvl, mid, false)
	return BuyPrice(cfg, Instance{Slot: slot, Tier: tier, Ilvl: ilvl,
		Attack: atk, Defense: def, Speed: spd}, 0)
}

// Forge makes the piece three make.
//
// The quality and the masterwork are the FORGE's own bands, not the shop's: an
// anvil is a gamble a lord chose, and the odds are on the screen before the tap.
// Luck tilts them the same way it tilts every other roll in the game.
func Forge(cfg *gameconfig.Bundle, rng *rand.Rand, pieces []Instance, luckBP int64) (Instance, error) {
	if err := CanForge(cfg, pieces); err != nil {
		return Instance{}, err
	}
	f := cfg.Forge
	slot, tier := pieces[0].Slot, pieces[0].Tier
	next := NextTier(cfg, tier)
	ilvl := ForgeILvl(pieces)

	defs := cfg.ItemDefsFor(slot, next)
	if len(defs) == 0 {
		return Instance{}, ErrForgeTier
	}
	def := defs[rng.IntN(len(defs))]

	luckBP = ClampLuckBP(luckBP)
	quality := f.Quality.MinPct
	if span := f.Quality.MaxPct - f.Quality.MinPct; span > 0 {
		quality += rng.Int64N(span + 1)
	}
	// Luck pulls the drawn value toward the top of the band rather than adding
	// to it, exactly as it does in the shop's roll, so a forged piece can never
	// leave the band the screen published.
	switch {
	case luckBP > 0:
		quality += (f.Quality.MaxPct - quality) * luckBP / (10000 + luckBP)
	case luckBP < 0:
		quality -= (quality - f.Quality.MinPct) * -luckBP / (10000 - luckBP)
	}
	masterwork := rng.Int64N(10000) < f.MasterworkChanceBP*(10000+luckBP)/10000

	atk, dfn, spd := Stat(cfg, slot, next, ilvl, quality, masterwork)
	return Instance{
		DefID: def.ID, Slot: def.Slot, Tier: def.Tier, Name: def.Name, Art: def.Art,
		Ilvl: ilvl, QualityPct: quality, Masterwork: masterwork,
		Attack: atk, Defense: dfn, Speed: spd,
	}, nil
}
