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

func TestSoldierBaseIsTypeTimesTierAndNothingElse(t *testing.T) {
	// A soldier has no level. Its stats are its type's base scaled by its tier,
	// full stop -- which is what makes the tier ladder strictly ordered.
	//
	// The old table was measured "at soldier level 30" and carried a
	// (1 + 0.09 * level) term that let four levels of Training push a tier past
	// the one above it.
	c := cfg(t)
	cases := []struct {
		typeID, tier         string
		wantA, wantD, wantHP int64
	}{
		{"peasant", "common", 8, 8, 40},
		{"peasant", "legendary", 29, 29, 144},
		{"peasant", "special", 61, 61, 304},
		{"mercenary", "common", 14, 12, 55},
		{"mercenary", "legendary", 50, 43, 198},
		{"gladiator", "common", 22, 18, 75},
		{"gladiator", "legendary", 79, 65, 270},
		{"gladiator", "special", 167, 137, 570},
	}
	for _, k := range cases {
		a, d, hp := SoldierBase(c, k.typeID, k.tier)
		if a != k.wantA || d != k.wantD || hp != k.wantHP {
			t.Errorf("%s %s = %d/%d/%d, want %d/%d/%d",
				k.typeID, k.tier, a, d, hp, k.wantA, k.wantD, k.wantHP)
		}
	}
}

// TestEveryTierBeatsTheOneBelowIt is the guarantee the whole rarity ladder rests
// on, checked on the real config rather than argued about.
func TestEveryTierBeatsTheOneBelowIt(t *testing.T) {
	c := cfg(t)
	for _, typeID := range []string{"peasant", "mercenary", "gladiator"} {
		var prevA, prevD, prevHP int64
		prev := ""
		for _, tier := range c.Tiers.Tiers {
			a, d, hp := SoldierBase(c, typeID, tier.ID)
			if prev != "" && (a <= prevA || d <= prevD || hp <= prevHP) {
				t.Errorf("%s: %s (%d/%d/%d) does not beat %s (%d/%d/%d)",
					typeID, tier.ID, a, d, hp, prev, prevA, prevD, prevHP)
			}
			prevA, prevD, prevHP, prev = a, d, hp, tier.ID
		}
	}
}

func TestACommonGladiatorRivalsARarePeasant(t *testing.T) {
	// The overlap that justifies the 40x price gap: type matters beyond the roll.
	// Without it, a lucky cheap recruit would make the expensive option pointless.
	c := cfg(t)
	ga, gd, ghp := SoldierBase(c, "gladiator", "common")
	pa, pd, php := SoldierBase(c, "peasant", "rare")
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
	//
	// This survives soldiers losing their level term, and it has to: most of a
	// unit's defense is its GEAR, which is rolled at the owner's level and still
	// grows with it. Flattening this to a constant was tried and saturated the
	// cap -- at k=60 anything above about 90 defense sat at the 60%% ceiling, so
	// armour stopped meaning anything for most of the game.
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
