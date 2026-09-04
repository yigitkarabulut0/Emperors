package items

import (
	"math/rand/v2"
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

func rng() *rand.Rand { return rand.New(rand.NewPCG(1, 2)) }

func TestStatsMatchTheDesignTable(t *testing.T) {
	// Spot values taken from docs/design/economy.md 5.3. If these drift, either
	// the config or the formula changed and the balance document is now a lie.
	c := cfg(t)
	cases := []struct {
		slot, tier          string
		ilvl                int64
		wantA, wantD, wantS int64
	}{
		{"weapon", "common", 30, 37, 7, 0},
		{"weapon", "legendary", 30, 133, 27, 0},
		{"weapon", "special", 30, 281, 56, 0},
		{"weapon", "legendary", 60, 230, 46, 0},
		{"armor", "common", 30, 7, 37, 0},
		{"horse", "common", 30, 19, 19, 22},
		{"horse", "legendary", 30, 67, 67, 80},
		{"horse", "special", 60, 243, 243, 292},
	}
	for _, k := range cases {
		a, d, s := Stat(c, k.slot, k.tier, k.ilvl, 100, false)
		if a != k.wantA || d != k.wantD || s != k.wantS {
			t.Errorf("%s %s ilvl%d = %d/%d/%d, design says %d/%d/%d",
				k.slot, k.tier, k.ilvl, a, d, s, k.wantA, k.wantD, k.wantS)
		}
	}
}

func TestBuyPricesMatchTheDesignTable(t *testing.T) {
	c := cfg(t)
	cases := []struct {
		tier string
		ilvl int64
		want int64
	}{
		{"common", 30, 265}, {"uncommon", 30, 563}, {"rare", 30, 1350},
		{"epic", 30, 3405}, {"legendary", 30, 9075}, {"mystic", 30, 24686},
		{"special", 30, 70286}, {"legendary", 60, 18945},
	}
	for _, k := range cases {
		a, d, s := Stat(c, "weapon", k.tier, k.ilvl, 100, false)
		it := Instance{Slot: "weapon", Tier: k.tier, Attack: a, Defense: d, Speed: s}
		if got := BuyPrice(c, it, 0); got != k.want {
			t.Errorf("weapon %s ilvl%d price = %d, design says %d", k.tier, k.ilvl, got, k.want)
		}
	}
}

func TestArbitrageIsImpossible(t *testing.T) {
	// The economic invariant the whole gear loop rests on: every buy-then-sell
	// round trip must lose money, even at the maximum shop discount. If this ever
	// passes at break-even, players print gold and the economy is gone.
	c := cfg(t)
	r := rng()
	for _, tier := range c.TierIDsAscending() {
		for _, slot := range []string{"weapon", "armor", "horse"} {
			for _, ilvl := range []int64{1, 30, 60} {
				it := Roll(c, r, slot, tier, ilvl)
				for _, discountBP := range []int64{0, 3000, MaxDiscountBP(c), 99999} {
					buy := BuyPrice(c, it, discountBP)
					sell := SellPrice(c, it)
					if sell >= buy {
						t.Errorf("%s %s ilvl%d at %dbp discount: buy %d, sell %d — arbitrage",
							slot, tier, ilvl, discountBP, buy, sell)
					}
				}
			}
		}
	}
}

func TestMaxDiscountIsDerivedFromTheSellRatio(t *testing.T) {
	// The cap must fall out of the sell ratio, so retuning the sell ratio in the
	// admin panel cannot silently open an arbitrage loop.
	c := cfg(t)
	if got, want := MaxDiscountBP(c), 10000-2*c.Items.Price.SellRatioBP; got != want {
		t.Errorf("MaxDiscountBP = %d, want %d", got, want)
	}
	// And it must actually bind: a request for more discount is clamped.
	it := Roll(c, rng(), "weapon", "rare", 30)
	if BuyPrice(c, it, 99999) != BuyPrice(c, it, MaxDiscountBP(c)) {
		t.Error("an absurd discount was not clamped to the cap")
	}
}

func TestSellIgnoresTheShopDiscount(t *testing.T) {
	// Sell must be computed from the UNDISCOUNTED price. If the discount leaked
	// into sell, a maxed discount would approach a break-even loop.
	c := cfg(t)
	it := Roll(c, rng(), "weapon", "epic", 30)
	full := BuyPrice(c, it, 0)
	if got, want := SellPrice(c, it), full*c.Items.Price.SellRatioBP/10000; got != want {
		t.Errorf("sell = %d, want %d (25%% of the undiscounted %d)", got, want, full)
	}
}

func TestHigherTiersAreStrictlyStronger(t *testing.T) {
	c := cfg(t)
	var prev int64
	for _, tier := range c.TierIDsAscending() {
		a, d, s := Stat(c, "weapon", tier, 30, 100, false)
		total := a + d + s
		if total <= prev {
			t.Errorf("tier %s (%d) is not stronger than the tier below (%d)", tier, total, prev)
		}
		prev = total
	}
}

func TestRollIsDeterministicForASeed(t *testing.T) {
	// Every roll must be reproducible from its seed, or an audit cannot verify
	// what the server gave a player and a support ticket becomes unanswerable.
	c := cfg(t)
	a := Roll(c, rand.New(rand.NewPCG(42, 7)), "weapon", "epic", 30)
	b := Roll(c, rand.New(rand.NewPCG(42, 7)), "weapon", "epic", 30)
	if a != b {
		t.Errorf("same seed gave different items:\n %+v\n %+v", a, b)
	}
}

func TestQualityStaysInRange(t *testing.T) {
	c := cfg(t)
	r := rng()
	for i := 0; i < 2000; i++ {
		it := Roll(c, r, "armor", "rare", 20)
		if it.QualityPct < c.Items.Quality.MinPct || it.QualityPct > c.Items.Quality.MaxPct {
			t.Fatalf("quality %d outside [%d,%d]", it.QualityPct, c.Items.Quality.MinPct, c.Items.Quality.MaxPct)
		}
	}
}

func TestRollTierNeverStarvesCommonsAndFavoursHighLevels(t *testing.T) {
	c := cfg(t)
	w := c.Items.Shop.BaseWeights
	luck := c.Items.Shop.LuckCoef

	count := func(level, n int) map[string]int {
		r := rand.New(rand.NewPCG(9, 9))
		out := map[string]int{}
		for i := 0; i < n; i++ {
			out[RollTier(c, r, w, luck, level)]++
		}
		return out
	}

	lo := count(1, 40000)
	hi := count(60, 40000)

	if lo["common"] == 0 {
		t.Error("commons never dropped at level 1")
	}
	// The contrast that makes a good drop feel good requires commons to survive
	// at max level too.
	if hi["common"] == 0 {
		t.Error("commons became impossible at level 60 — that removes the contrast good drops need")
	}
	if hi["epic"] <= lo["epic"] {
		t.Errorf("level did not shift mass up the ladder: epic %d at lv1, %d at lv60", lo["epic"], hi["epic"])
	}
	if lo["common"] <= lo["uncommon"] {
		t.Error("commons are not the most likely tier at level 1")
	}
}
