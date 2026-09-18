//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

func slotOf(v *service.CourtStore, slot int) service.DealView {
	for _, d := range v.Deals.Slots {
		if d.Slot == slot {
			return d
		}
	}
	return service.DealView{Slot: -1}
}

// The day's four are fixed at the first look; the gift is claimed once; a deal
// is bought with diamonds, once, and refused without them; the next day draws
// four new ones.
func TestTheDailyDeals(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)

	first, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Deals.Slots) != 4 || first.Deals.ResetsIn <= 0 || first.Deals.ResetsIn > 86400 {
		t.Fatalf("the day's deals: %d slots, resets in %d", len(first.Deals.Slots), first.Deals.ResetsIn)
	}
	again, _ := s.d.GetCourtStore(s.ctx, p.ID)
	for i := range first.Deals.Slots {
		if again.Deals.Slots[i].ID != first.Deals.Slots[i].ID {
			t.Fatalf("slot %d changed between two looks", i)
		}
	}
	if first.Herald.Enabled {
		t.Fatal("Herald's Tidings is open on a server with no adverts")
	}
	gift := slotOf(first, 0)
	if gift.Kind != service.DealFree || gift.Diamonds != 0 || len(gift.Lines) == 0 {
		t.Fatalf("the gift: %+v", gift)
	}
	if b, _ := s.d.GetBadges(s.ctx, p.ID); !b.StoreFree {
		t.Fatal("the store's badge does not say a gift waits")
	}

	// The gift, once.
	p = s.reload(p.ID)
	got, err := s.d.ClaimDeal(s.ctx, p.ID, 0, p.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Lines) == 0 || !slotOfDeals(got.Deals, 0).Claimed {
		t.Fatalf("the gift claimed: lines %v, claimed %v", got.Lines, slotOfDeals(got.Deals, 0).Claimed)
	}
	p = s.reload(p.ID)
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 0, p.ActionSeq+1); !errors.Is(err, service.ErrNothingToClaim) {
		t.Fatalf("the gift claimed twice: %v", err)
	}
	if b, _ := s.d.GetBadges(s.ctx, p.ID); b.StoreFree {
		t.Fatal("the badge still says a gift waits after it was claimed")
	}

	// A deal costs diamonds: refused without them, and nothing moves.
	potions := slotOf(first, 1)
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 1, p.ActionSeq+1); !errors.Is(err, service.ErrNotEnoughDiamonds) {
		t.Fatalf("a deal bought with no diamonds: %v", err)
	}
	if v, _ := s.d.GetCourtStore(s.ctx, p.ID); slotOf(v, 1).Claimed {
		t.Fatal("a refused deal was marked taken")
	}
	s.buy(p, "gems.330") // 660 diamonds
	p = s.reload(p.ID)
	before := p.Diamonds
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 1, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	p = s.reload(p.ID)
	if p.Diamonds != before-potions.Diamonds {
		t.Fatalf("the potions cost %d, want %d", before-p.Diamonds, potions.Diamonds)
	}
	var potionsHeld int64
	_ = pool.QueryRow(s.ctx, `SELECT coalesce(sum(qty), 0) FROM app.player_tokens
		WHERE player_id = $1 AND token = 'energy_potion'`, p.ID).Scan(&potionsHeld)
	if potionsHeld <= 0 {
		t.Fatal("the potions bought were not delivered")
	}
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 1, p.ActionSeq+1); !errors.Is(err, service.ErrNothingToClaim) {
		t.Fatalf("a deal bought twice: %v", err)
	}

	// The frame slot: the cosmetic is theirs, and the slot reads taken.
	frame := slotOf(first, 3)
	if frame.Kind != service.DealCosmetic || frame.Cosmetic == nil || frame.Diamonds >= frame.Was {
		t.Fatalf("the frame slot: %+v", frame)
	}
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 3, p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	wr, _ := s.d.GetWardrobe(s.ctx, p.ID)
	owns := false
	for _, c := range wr.Items {
		if c.ID == frame.ID {
			owns = c.Owned
		}
	}
	if !owns {
		t.Fatalf("%s was bought and is not in the wardrobe", frame.ID)
	}
	p = s.reload(p.ID)

	// Out of step: the sequence guards a deal like any other spend.
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 2, p.ActionSeq+5); err == nil {
		t.Fatal("a deal bought with a stale action_seq went through")
	}

	// The next day: four new ones, none taken.
	s.now = s.now.Add(25 * time.Hour)
	next, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range next.Deals.Slots {
		if d.Claimed && d.Kind != service.DealCosmetic {
			t.Fatalf("slot %d is taken on a new day", d.Slot)
		}
	}
	if next.Deals.Day == first.Deals.Day {
		t.Fatal("the day did not turn")
	}
}

func slotOfDeals(v service.DealsView, slot int) service.DealView {
	for _, d := range v.Slots {
		if d.Slot == slot {
			return d
		}
	}
	return service.DealView{Slot: -1}
}

// A deal the catalogue no longer has is refused as stale, and the view leaves
// it out rather than sell what cannot be delivered.
func TestAStaleDealIsRefused(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	if _, err := s.d.GetCourtStore(s.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	s.exec(`UPDATE app.player_deals SET slots = jsonb_set(slots, '{1,id}', '"a_deal_long_gone"') WHERE player_id = $1`, p.ID)
	v, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if slotOf(v, 1).Slot != -1 {
		t.Fatal("a deal the catalogue does not have is on the shelf")
	}
	p = s.reload(p.ID)
	if _, err := s.d.ClaimDeal(s.ctx, p.ID, 1, p.ActionSeq+1); !errors.Is(err, service.ErrDealStale) {
		t.Fatalf("a stale deal: %v", err)
	}
}

// The Steward claims the day's gift for a lord he serves, and never spends
// their diamonds on a deal.
func TestTheStewardTakesTheGiftOnly(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	steward, _ := s.txn(p, "comfort.steward", "", map[string]any{"type": iap.TypeNonConsumable})
	if _, err := s.d.VerifyApple(s.ctx, p.ID, steward); err != nil {
		t.Fatal(err)
	}
	s.buy(p, "gems.330")
	before := s.reload(p.ID).Diamonds
	if _, err := s.d.RunSteward(s.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	v, _ := s.d.GetCourtStore(s.ctx, p.ID)
	if !slotOf(v, 0).Claimed {
		t.Fatal("the Steward left the day's gift in its box")
	}
	for _, slot := range []int{1, 2, 3} {
		if slotOf(v, slot).Claimed {
			t.Fatalf("the Steward bought deal %d", slot)
		}
	}
	// The gift may itself be diamonds; a deal would only ever take them away.
	if after := s.reload(p.ID).Diamonds; after < before {
		t.Fatalf("the Steward spent %d diamonds", before-after)
	}
}
