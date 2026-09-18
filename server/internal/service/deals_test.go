package service

import (
	"math"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func dealsConfig(t *testing.T) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// A lord's four are the same however often they look on a day, and another
// day or another lord draws again.
func TestTheDaysDealsAreFixed(t *testing.T) {
	b := dealsConfig(t)
	secret := []byte("deals-test")
	lord := uuid.MustParse("5f7c4f7a-8f0e-4b9a-9f7e-2b1c3d4e5f60")
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	first := pickDeals(b, secret, lord, day, nil)
	if len(first) != dealSlots {
		t.Fatalf("%d slots, want %d", len(first), dealSlots)
	}
	for i := 0; i < 5; i++ {
		again := pickDeals(b, secret, lord, day, nil)
		for s := range first {
			if again[s] != first[s] {
				t.Fatalf("slot %d changed between looks on one day: %+v then %+v", s, first[s], again[s])
			}
		}
	}
	differs := false
	for d := 1; d <= 14 && !differs; d++ {
		next := pickDeals(b, secret, lord, day.AddDate(0, 0, d), nil)
		for s := range first {
			differs = differs || next[s] != first[s]
		}
	}
	if !differs {
		t.Fatal("two weeks of days all drew the same four")
	}
	if first[dealGift].Diamonds != 0 {
		t.Fatalf("the gift costs %d diamonds", first[dealGift].Diamonds)
	}
	for _, s := range []int{dealPotions, dealCharters, dealCosmetic} {
		if first[s].Diamonds <= 0 {
			t.Fatalf("slot %d is priced at %d", s, first[s].Diamonds)
		}
	}
}

// Over many lords, each pool is drawn in proportion to its weights, and the
// frame slot offers only what is sold, at the discount, never what is owned.
func TestTheDealsFollowTheirWeights(t *testing.T) {
	b := dealsConfig(t)
	secret := []byte("deals-weights")
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	const lords = 20000
	seen := map[string]int{}
	owned := map[string]*time.Time{"frame_laurel": nil}
	for i := 0; i < lords; i++ {
		picks := pickDeals(b, secret, uuid.New(), day, owned)
		for _, p := range picks {
			seen[p.ID]++
		}
		c := b.Cosmetic(picks[dealCosmetic].ID)
		if c == nil || c.ShopDiamonds <= 0 || c.DefaultOwned {
			t.Fatalf("the frame slot offered %q, which the shop does not sell", picks[dealCosmetic].ID)
		}
		if c.ID == "frame_laurel" {
			t.Fatal("the frame slot offered a cosmetic the lord owns")
		}
		if want := c.ShopDiamonds - c.ShopDiamonds*b.Commerce.Deals.CosmeticOffBP/10000; picks[dealCosmetic].Diamonds != want ||
			picks[dealCosmetic].Was != c.ShopDiamonds {
			t.Fatalf("%s offered at %d (was %d), want %d (was %d)", c.ID, picks[dealCosmetic].Diamonds,
				picks[dealCosmetic].Was, want, c.ShopDiamonds)
		}
	}
	for _, pool := range [][]gameconfig.DealGood{b.Commerce.Deals.Gift, b.Commerce.Deals.Potions, b.Commerce.Deals.Charters} {
		total := 0
		for _, g := range pool {
			total += g.Weight
		}
		for _, g := range pool {
			want := float64(g.Weight) / float64(total)
			got := float64(seen[g.ID]) / lords
			if math.Abs(got-want) > 0.015 {
				t.Errorf("%s drawn %.3f of the time, want %.3f", g.ID, got, want)
			}
		}
	}
}

// A lord who owns every cosmetic the shop sells is offered none: the frame slot
// stays empty rather than sell something its picture does not show.
func TestTheFrameSlotSellsOnlyWhatItShows(t *testing.T) {
	b := dealsConfig(t)
	owned := map[string]*time.Time{}
	for _, c := range b.Cosmetics.Items {
		owned[c.ID] = nil
	}
	picks := pickDeals(b, []byte("x"), uuid.New(), time.Now().UTC(), owned)
	if picks[dealCosmetic].ID != "" || picks[dealCosmetic].Diamonds != 0 {
		t.Fatalf("a lord who owns everything was offered %+v", picks[dealCosmetic])
	}
}
