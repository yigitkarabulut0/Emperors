package service

import (
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// What purchases leave on a lord, read off the player row every request
// already has. Each is a fixed comfort, never a bonus in a bucket (FAIR).

// patronage is Crown Patronage's terms, or nil when the catalog sells none.
func (d Deps) patronage() *gameconfig.PatronageConfig {
	for i := range d.Config.Commerce.Products {
		if pa := d.Config.Commerce.Products[i].Patronage; pa != nil {
			return pa
		}
	}
	return nil
}

// patronActive reports whether Crown Patronage runs for this lord now.
func patronActive(p sqlcdb.AppPlayer, now time.Time) bool {
	return p.PatronUntil != nil && p.PatronUntil.After(now)
}

// vipLevel is the lord's Royal Favour level.
func (d Deps) vipLevel(p sqlcdb.AppPlayer) int { return d.Config.VIPLevel(p.VipPoints) }

// bagCap is how many pieces of gear a lord may hold: the balance's bag
// (items.inventory_cap -- a larger armory is a publish, not a deploy), plus the
// Quartermaster's slots bought for good, plus Royal Favour's, plus the patron's
// while the patronage runs. It is the one place a bag is sized, so every
// refusal agrees with every count shown.
func (d Deps) bagCap(p sqlcdb.AppPlayer) int64 {
	n := d.Config.Items.InventoryCap + int64(p.BagBonus)
	if t := d.Config.VIPTier(d.vipLevel(p)); t != nil {
		n += int64(t.BagBonus)
	}
	if pa := d.patronage(); pa != nil && patronActive(p, d.Now()) {
		n += int64(pa.BagBonus)
	}
	return n
}

// freeRefills is how many of the day's refills cost nothing: the patron's.
func (d Deps) freeRefills(p sqlcdb.AppPlayer, now time.Time) int {
	if pa := d.patronage(); pa != nil && patronActive(p, now) {
		return pa.FreeRefillsPerDay
	}
	return 0
}

// stewardActive reports whether the Steward serves this lord: bought for
// good, or part of a running patronage.
func (d Deps) stewardActive(p sqlcdb.AppPlayer, now time.Time) bool {
	if p.StewardOwned {
		return true
	}
	pa := d.patronage()
	return pa != nil && pa.Steward && patronActive(p, now)
}
