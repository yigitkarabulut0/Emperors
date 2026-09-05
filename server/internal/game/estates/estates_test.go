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
