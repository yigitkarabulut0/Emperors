package army

import (
	"testing"

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

func TestSoldierBaseMatchesTheDesignTable(t *testing.T) {
	// Values from docs/design/economy.md 6.3 at soldier level 30.
	//
	// One deliberate divergence: the doc lists Mercenary legendary as 187 attack,
	// but its own formula gives 14 * 3.60 * 3.7 = 186.48 -> 186. The doc cell is a
	// rounding artefact; the formula is the source of truth.
	c := cfg(t)
	cases := []struct {
		typeID, tier         string
		wantA, wantD, wantHP int64
	}{
		{"peasant", "common", 30, 30, 148},
		{"peasant", "legendary", 107, 107, 533},
		{"peasant", "special", 225, 225, 1125},
		{"mercenary", "common", 52, 44, 204},
		{"mercenary", "legendary", 186, 160, 733},
		{"gladiator", "common", 81, 67, 278},
		{"gladiator", "legendary", 293, 240, 999},
		{"gladiator", "special", 619, 506, 2109},
	}
	for _, k := range cases {
		a, d, hp := SoldierBase(c, k.typeID, k.tier, 30)
		if a != k.wantA || d != k.wantD || hp != k.wantHP {
			t.Errorf("%s %s lv30 = %d/%d/%d, want %d/%d/%d",
				k.typeID, k.tier, a, d, hp, k.wantA, k.wantD, k.wantHP)
		}
	}
}

func TestACommonGladiatorRivalsARarePeasant(t *testing.T) {
	// The overlap that justifies the 40x price gap: type matters beyond the roll.
	// Without it, a lucky cheap recruit would make the expensive option pointless.
	c := cfg(t)
	ga, gd, ghp := SoldierBase(c, "gladiator", "common", 30)
	pa, pd, php := SoldierBase(c, "peasant", "rare", 30)
	if ga+gd+ghp < (pa+pd+php)*85/100 {
		t.Errorf("a common Gladiator (%d/%d/%d) is far weaker than a rare Peasant (%d/%d/%d)",
			ga, gd, ghp, pa, pd, php)
	}
}

func TestHeroIsNeverZero(t *testing.T) {
	// An explicit design requirement: a player with no soldiers and no gear must
	// still be able to fight and progress.
	c := cfg(t)
	a, d := HeroBase(c, 1, 0, 0)
	if a <= 0 || d <= 0 {
		t.Fatalf("a fresh level-1 player has attack %d defense %d", a, d)
	}
	if hp := HeroHP(c, 1, d); hp <= 0 {
		t.Fatalf("a fresh level-1 player has %d hp", hp)
	}
}

func TestDamageReductionIsCappedAndLevelNormalised(t *testing.T) {
	c := cfg(t)
	if got := DamageReductionBP(c, 0, 10); got != 0 {
		t.Errorf("zero defense gave %d bp reduction", got)
	}
	// Absurd defense must still hit the ceiling, or a stacked-defense build is
	// unkillable and the arena stalls.
	if got := DamageReductionBP(c, 1<<40, 10); got != c.Soldiers.Combat.DRCapBP {
		t.Errorf("huge defense gave %d bp, want the %d bp cap", got, c.Soldiers.Combat.DRCapBP)
	}
	// The same armour is worth less against a higher-level attacker.
	lo := DamageReductionBP(c, 200, 5)
	hi := DamageReductionBP(c, 200, 50)
	if hi >= lo {
		t.Errorf("armour did not normalise by level: %d bp at lv5 vs %d bp at lv50", lo, hi)
	}
}

func TestEffectiveHPExceedsRawHPWhenArmoured(t *testing.T) {
	c := cfg(t)
	raw := int64(1000)
	if got := EffectiveHP(c, raw, 0, 10); got != raw {
		t.Errorf("unarmoured EHP = %d, want %d", got, raw)
	}
	if got := EffectiveHP(c, raw, 500, 10); got <= raw {
		t.Errorf("armoured EHP = %d, want more than %d", got, raw)
	}
}

func TestMightIsMonotoneInEveryStat(t *testing.T) {
	// Required for matchmaking and for an honest "you are stronger" UI: adding
	// any stat must never lower Might.
	base := []Unit{{Attack: 100, EHP: 1000}}
	m0 := Sum(base).Might

	more := []Unit{{Attack: 101, EHP: 1000}}
	if Sum(more).Might < m0 {
		t.Error("more attack lowered Might")
	}
	tougher := []Unit{{Attack: 100, EHP: 1001}}
	if Sum(tougher).Might < m0 {
		t.Error("more effective HP lowered Might")
	}
	extra := []Unit{{Attack: 100, EHP: 1000}, {Attack: 1, EHP: 1}}
	if Sum(extra).Might < m0 {
		t.Error("adding a unit lowered Might")
	}
}

func TestMightIsDeterministicAndIntegerOnly(t *testing.T) {
	// isqrt rather than math.Sqrt: Might drives matchmaking and the leaderboard,
	// and a float could differ in the last bit between architectures.
	u := []Unit{{Attack: 9301, EHP: 126397}}
	a, b := Sum(u).Might, Sum(u).Might
	if a != b {
		t.Fatalf("Might is not stable: %d then %d", a, b)
	}
	// 2*sqrt(9301 * 126397) = 2*sqrt(1_175_618_497) ~= 2*34287 = 68574
	if a < 68000 || a > 69000 {
		t.Errorf("Might = %d, expected roughly 68.6k from the design's level-60 example", a)
	}
}

func TestIsqrtIsExact(t *testing.T) {
	for _, n := range []int64{0, 1, 2, 3, 4, 8, 9, 15, 16, 9301 * 126397, 1 << 40} {
		r := isqrt(n)
		if r*r > n || (r+1)*(r+1) <= n {
			t.Errorf("isqrt(%d) = %d is not the floor of the square root", n, r)
		}
	}
}
