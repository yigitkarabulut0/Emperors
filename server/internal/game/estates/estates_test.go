package estates

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func cfg(t *testing.T) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestOneHoldingLevelChangesTheRate(t *testing.T) {
	// The bug this guards: the rate was kept per SECOND, and at level 5 the base
	// (29,904 milli/hour) floored to 8 milli/second with or without a wheat farm.
	// A player bought an estate and watched nothing happen.
	c := cfg(t)
	bare := TaxRate(c, 5, map[string]int{}, 0)
	one := TaxRate(c, 5, map[string]int{"wheat_farm": 1}, 0)
	if one <= bare {
		t.Errorf("a wheat farm level changed nothing: %d -> %d milli/hour", bare, one)
	}
}

func TestTaxIsNotAFunctionOfGear(t *testing.T) {
	// Idle income must not depend on Might or equipment, or PvP power buys income
	// which buys PvP power and the strong pull away permanently. This asserts the
	// signature stays free of any such input.
	c := cfg(t)
	a := TaxRate(c, 20, map[string]int{"wheat_farm": 3}, 0)
	b := TaxRate(c, 20, map[string]int{"wheat_farm": 3}, 0)
	if a != b {
		t.Error("tax rate is not a pure function of level and holdings")
	}
}

func TestOfflineCapBounds(t *testing.T) {
	c := cfg(t)
	rate := TaxRate(c, 30, map[string]int{}, 0)
	start := time.Date(2026, 9, 4, 0, 0, 0, 0, time.UTC)
	capSec := c.Estates.Tax.OfflineCapSeconds

	day := SettleTax(TaxState{UpdatedAt: start}, rate, capSec, start.Add(24*time.Hour))
	exact := SettleTax(TaxState{UpdatedAt: start}, rate, capSec, start.Add(time.Duration(capSec)*time.Second))
	if day.Milli != exact.Milli {
		t.Errorf("a day away accrued %d, the %ds cap allows %d — the cap is not binding",
			day.Milli, capSec, exact.Milli)
	}
}

func TestTitheBarnRaisesRateAndCap(t *testing.T) {
	c := cfg(t)
	plain := Derive(c, 30, map[string]int{}, map[string]int{})
	tithed := Derive(c, 30, map[string]int{"tithe_barn": 10}, map[string]int{})

	if tithed.TaxMilliPerHour <= plain.TaxMilliPerHour {
		t.Error("the Tithe Barn did not raise the tax rate")
	}
	if tithed.OfflineCapSeconds <= plain.OfflineCapSeconds {
		t.Error("the Tithe Barn did not extend the offline cap")
	}
}

func TestUpgradesAreAdditiveNotCompounding(t *testing.T) {
	c := cfg(t)
	one := Derive(c, 10, map[string]int{"granary": 1}, map[string]int{})
	ten := Derive(c, 10, map[string]int{"granary": 10}, map[string]int{})

	gran := c.Upgrade("granary")
	if got, want := ten.Bonuses[0]-one.Bonuses[0], gran.PerLevel*9; got != want {
		t.Errorf("levels 1->10 added %d bp, want %d — upgrades must be additive, not compounding", got, want)
	}
}

func TestLevelsAreClampedToTheirMaximum(t *testing.T) {
	c := cfg(t)
	sane := Derive(c, 10, map[string]int{"granary": 20}, map[string]int{})
	absurd := Derive(c, 10, map[string]int{"granary": 9999}, map[string]int{})
	if sane.Bonuses[0] != absurd.Bonuses[0] {
		t.Error("an out-of-range level was not clamped to the upgrade's maximum")
	}
}

func TestTaxBonusIsCappedAndNeverCompounds(t *testing.T) {
	// Two bugs in one place, both of which let passive income outrun playing.
	//
	// Tax is the one percentage bucket that never passes through
	// economy.ApplyBucket -- it scales a stored hourly RATE, not an amount at a
	// call site -- so for a long time it had no ceiling at all, and a kingdom's
	// Royal Treasury was multiplied onto a rate the family tree had already
	// multiplied. A Tithe Barn at +100% and a Treasury at +40% came out as x2.4.
	c := cfg(t)
	holdings := map[string]int{"wheat_farm": 5, "watermill": 5}

	t.Run("clamped to the ceiling", func(t *testing.T) {
		atCap := TaxRate(c, 30, holdings, gameconfig.MaxTaxIncomeBP)
		wayOver := TaxRate(c, 30, holdings, gameconfig.MaxTaxIncomeBP*10)
		if wayOver != atCap {
			t.Errorf("a bonus past the ceiling still raised the rate: %d vs %d", wayOver, atCap)
		}
	})

	t.Run("family and kingdom add, they do not multiply", func(t *testing.T) {
		// Derive gives the family's share; ApplyKingdom must fold the kingdom's
		// into the SAME sum and recompute, not scale the finished rate again.
		family := Derive(c, 30, map[string]int{"tithe_barn": 20}, holdings)
		e := family
		ApplyKingdom(c, &e, 30, map[string]int{"royal_treasury": 10}, holdings)

		var kingdomBP int64
		for _, u := range c.Kingdoms.Upgrades {
			if u.ID == "royal_treasury" {
				kingdomBP = u.PerLevel * int64(u.MaxLevel)
			}
		}
		want := TaxRate(c, 30, holdings, family.TaxIncomeBP+kingdomBP)
		if e.TaxMilliPerHour != want {
			t.Errorf("kingdom bonus compounded: got %d, want %d (additive)", e.TaxMilliPerHour, want)
		}
		// And the compounding form is genuinely different, or this proves nothing.
		compounded := family.TaxMilliPerHour * (10000 + kingdomBP) / 10000
		if compounded == want {
			t.Skip("family and kingdom bonuses too small to tell the two forms apart")
		}
	})
}

func TestLaterEstatesArePayingInvestments(t *testing.T) {
	// The ladder shipped with cost growing faster than yield, so payback got
	// WORSE the further up you went: the Ducal Mint a level-55 player finally
	// unlocked took 737 hours to pay for itself against the Wheat Farm's 283.
	// The estate you wait longest for must not be the worst thing to buy.
	c := cfg(t)
	var prev float64
	var prevID string
	for _, h := range c.Estates.Holdings {
		var total int64
		for i := 0; i < h.MaxLevel && i < len(h.Costs); i++ {
			total += h.Costs[i]
		}
		yield := float64(h.TaxMilliPerHourPerLevel) / 1000 * float64(h.MaxLevel)
		payback := float64(total) / yield
		if prev > 0 && payback > prev {
			t.Errorf("%s pays back in %.0fh, worse than %s at %.0fh", h.ID, payback, prevID, prev)
		}
		prev, prevID = payback, h.ID
	}
}
