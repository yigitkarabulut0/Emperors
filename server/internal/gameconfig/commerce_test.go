package gameconfig

import (
	"strings"
	"testing"
)

// mutate loads the seed, changes it, and returns what Validate says.
func mutate(t *testing.T, change func(b *Bundle)) string {
	t.Helper()
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	change(b)
	if err := b.build(); err != nil {
		return err.Error()
	}
	if err := b.Validate(); err != nil {
		return err.Error()
	}
	return ""
}

func product(b *Bundle, id string) *Product {
	for i := range b.Commerce.Products {
		if b.Commerce.Products[i].ID == id {
			return &b.Commerce.Products[i]
		}
	}
	panic("no product " + id)
}

// The seed's catalog loads, and every product is on sale under the app's prefix.
func TestTheSeedCatalog(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	if b.Product("gems_700") == nil || b.ProductByStoreID("com.emperors.game.gems.700") == nil {
		t.Fatal("the 700-diamond pack is not in the catalog under its id and its store id")
	}
	if b.VIPLevel(0) != 0 || b.VIPLevel(99) != 1 || b.VIPLevel(199999) != 10 || b.VIPLevel(1_000_000) != 10 {
		t.Fatalf("Royal Favour levels: %d %d %d", b.VIPLevel(0), b.VIPLevel(99), b.VIPLevel(199999))
	}
}

// FAIR, product by product: money never buys gold, experience, favour, gear,
// a timed bonus or a token whose use rolls for loot.
func TestMoneyNeverBuysGoldOrPower(t *testing.T) {
	for name, change := range map[string]func(b *Bundle){
		"gold":       func(b *Bundle) { product(b, "gems_60").Grant.Gold = 1000 },
		"gold wages": func(b *Bundle) { product(b, "gems_60").Grant.GoldWages = 60 },
		"experience": func(b *Bundle) { product(b, "gems_60").Grant.XP = 500 },
		"favour":     func(b *Bundle) { product(b, "gems_60").Grant.Favour = 10 },
		"gear":       func(b *Bundle) { product(b, "gems_60").Grant.Items = []ItemGrant{{Tier: "rare", Count: 1}} },
		"a timed bonus": func(b *Bundle) {
			product(b, "gems_60").Grant.Boosts = []BoostGrant{{Bucket: BucketXP, BP: 5000, Hours: 24}}
		},
		"a loot token": func(b *Bundle) {
			b.Rewards.Tokens = append(b.Rewards.Tokens, TokenDef{ID: "chest_key", Name: "Chest Key", Icon: "key"})
			product(b, "gems_60").Grant.Tokens = map[string]int64{"chest_key": 1}
		},
		"gold for the kingdom": func(b *Bundle) { product(b, "largesse").Largesse.MemberGrant.Gold = 5000 },
	} {
		if got := mutate(t, change); got == "" {
			t.Errorf("a product selling %s was accepted", name)
		}
	}
}

// What the store could not sell, or would sell wrongly, is refused.
func TestTheCatalogIsSellable(t *testing.T) {
	for want, change := range map[string]func(b *Bundle){
		"usd_cents must be positive":  func(b *Bundle) { product(b, "gems_330").USDCents = 0 },
		"does not start with":         func(b *Bundle) { product(b, "gems_330").StoreID = "com.other.app.gems" },
		"no more diamonds per dollar": func(b *Bundle) { product(b, "gems_4000").Grant.Diamonds = 1000 },
		"has no fallback_diamonds":    func(b *Bundle) { product(b, "starter").FallbackDiamonds = 0 },
		"needs its patronage":         func(b *Bundle) { product(b, "patronage").Patronage = nil },
		"a lasting right":             func(b *Bundle) { product(b, "steward").Grant.Diamonds = 10 },
		"sold once per account":       func(b *Bundle) { product(b, "offer_l10").Limit = 0 },
		"unknown cosmetic":            func(b *Bundle) { product(b, "starter").Grant.Cosmetics = []string{"frame_nowhere"} },
		"wear the":                    func(b *Bundle) { product(b, "gems_60").Badge = "best_value" },
		"must cost more":              func(b *Bundle) { b.Commerce.VIP[3].Points = b.Commerce.VIP[2].Points },
		"commerce section is missing": func(b *Bundle) { b.Commerce = CommerceConfig{} },
		"duplicate store id": func(b *Bundle) {
			product(b, "gems_60").StoreID = product(b, "gems_330").StoreID
		},
	} {
		got := mutate(t, change)
		if !strings.Contains(got, want) {
			t.Errorf("expected a refusal containing %q, got %q", want, got)
		}
	}
}

// The daily deals: the gift is free and may be anything; the other slots are
// bought with diamonds, keep FAIR, hold only their painted goods, and say what
// they save at the store's real prices.
func TestTheDealsKeepTheirSlotsAndTheirWord(t *testing.T) {
	if msg := mutate(t, func(b *Bundle) {}); msg != "" {
		t.Fatalf("the seed's deals do not validate: %s", msg)
	}
	for name, c := range map[string]struct {
		change func(b *Bundle)
		want   string
	}{
		"diamonds for gold": {func(b *Bundle) { b.Commerce.Deals.Potions[0].Grant.GoldWages = 30 }, "potions"},
		"the potion slot selling charters": {func(b *Bundle) {
			b.Commerce.Deals.Potions[0].Grant.Tokens = map[string]int64{"shield_8h": 1}
		}, "sells energy_potion tokens and nothing else"},
		"a saving that lies": {func(b *Bundle) { b.Commerce.Deals.Charters[0].Was = 99 }, "at the store's own price"},
		"a deal dearer than the store": {func(b *Bundle) {
			b.Commerce.Deals.Potions[0].Diamonds = b.Commerce.Deals.Potions[0].Was
		}, "no cheaper"},
		"a gift with a price":  {func(b *Bundle) { b.Commerce.Deals.Gift[0].Diamonds = 5 }, "free"},
		"an empty pool":        {func(b *Bundle) { b.Commerce.Deals.Charters = nil }, "charters is empty"},
		"no weight":            {func(b *Bundle) { b.Commerce.Deals.Gift[0].Weight = 0 }, "weight"},
		"a repeated id":        {func(b *Bundle) { b.Commerce.Deals.Potions[1].ID = b.Commerce.Deals.Potions[0].ID }, "repeats"},
		"a discount of it all": {func(b *Bundle) { b.Commerce.Deals.CosmeticOffBP = 10000 }, "cosmetic_off_bp"},
	} {
		if msg := mutate(t, c.change); !strings.Contains(msg, c.want) {
			t.Errorf("%s: Validate said %q, want it to mention %q", name, msg, c.want)
		}
	}
	// A dearer first refill makes the potions' `was` stale: refused until regenerated.
	if msg := mutate(t, func(b *Bundle) { b.Progression.Store.EnergyRefillPrices[0] = 25 }); !strings.Contains(msg, "at the store's own price") {
		t.Errorf("a refill price change left the deals' savings unchecked: %q", msg)
	}
}
