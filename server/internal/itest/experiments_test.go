//go:build integration

package itest

import (
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
)

// starterOffers is which Founder's Crates a lord's store shows.
func starterOffers(d *desk, id uuid.UUID) []string {
	d.t.Helper()
	v, err := d.d.GetCourtStore(d.ctx, id)
	if err != nil {
		d.t.Fatal(err)
	}
	var out []string
	for _, p := range v.Products {
		pr := d.d.Config.Product(p.ID)
		if pr == nil || p.USDCents != pr.USDCents {
			d.t.Fatalf("the store's %s says %d cents; the catalogue %v", p.ID, p.USDCents, pr)
		}
		if pr.Offer != nil && pr.Offer.Slot == "starter" {
			out = append(out, p.ID)
		}
	}
	return out
}

func exposures(d *desk, test string, id uuid.UUID) (n int, arm string) {
	_ = pool.QueryRow(d.ctx, `SELECT count(*), coalesce(max(arm), '') FROM app.experiment_exposures
		WHERE experiment = $1 AND player_id = $2`, test, id).Scan(&n, &arm)
	return n, arm
}

// An offer under test: while it is off everyone is shown the control and
// nobody is counted; while it runs each lord is shown their own arm, once, and
// the panel counts who was shown what and who bought it, in Production only.
func TestAnOfferUnderTest(t *testing.T) {
	d := newDesk(t)
	e := &d.d.Config.Commerce.Experiments[0]
	e.ID = "starter_price_" + uuid.NewString()[:8] // this run's own results
	control, richer := e.Arms[0], e.Arms[1]

	e.Active = false
	off := d.player(8, 0)
	if got := starterOffers(d, off.ID); len(got) != 1 || got[0] != control.Product {
		t.Fatalf("test off: the store shows %v; want only %s", got, control.Product)
	}
	if n, _ := exposures(d, e.ID, off.ID); n != 0 {
		t.Fatal("a lord was counted in a test that is off")
	}

	e.Active = true
	// Switched on, a lord who has had the control is not shown the other arm.
	if got := starterOffers(d, off.ID); len(got) != 1 || got[0] != control.Product {
		t.Fatalf("after the test is switched on, a lord who had the control is shown %v", got)
	}

	inArm := map[string][]uuid.UUID{}
	for i := 0; i < 24; i++ {
		p := d.player(8, 0)
		got := starterOffers(d, p.ID)
		if len(got) != 1 {
			t.Fatalf("lord %d is shown %v; want one crate", i, got)
		}
		n, arm := exposures(d, e.ID, p.ID)
		if n != 1 || (arm == control.ID) != (got[0] == control.Product) {
			t.Fatalf("lord %d: shown %s, counted %d times in %q", i, got[0], n, arm)
		}
		if again := starterOffers(d, p.ID); len(again) != 1 || again[0] != got[0] {
			t.Fatalf("lord %d's crate changed between two looks: %v then %v", i, got, again)
		}
		inArm[arm] = append(inArm[arm], p.ID)
	}
	if len(inArm[control.ID]) == 0 || len(inArm[richer.ID]) == 0 {
		t.Fatalf("24 lords all in one arm: %d and %d", len(inArm[control.ID]), len(inArm[richer.ID]))
	}

	// The badges are a look too: a lord who reaches the level is shown their
	// crate without opening the store, so the popup can offer it.
	fresh := d.player(8, 0)
	b, err := d.d.GetBadges(d.ctx, fresh.ID)
	if err != nil || b.OffersUnseen != 1 {
		t.Fatalf("a new level 8 lord's badges: %+v, %v; want one unseen offer", b, err)
	}
	if n, _ := exposures(d, e.ID, fresh.ID); n != 1 {
		t.Fatal("the offer the badges opened was not counted")
	}

	// One lord in each arm buys their crate; a sandbox purchase is not counted.
	buy := func(id uuid.UUID, product string, env string) {
		p := d.reload(id)
		store := d.d.Config.Product(product).StoreID[len("com.emperors.game."):]
		signed, _ := d.txn(p, store, "", map[string]any{"environment": env})
		if _, err := d.d.VerifyApple(d.ctx, p.ID, signed); err != nil {
			t.Fatalf("buying %s: %v", product, err)
		}
	}
	buy(inArm[control.ID][0], control.Product, iap.EnvProduction)
	buy(inArm[richer.ID][0], richer.Product, iap.EnvProduction)
	if len(inArm[richer.ID]) > 1 {
		buy(inArm[richer.ID][1], richer.Product, iap.EnvSandbox)
	}

	all, err := d.svc.Experiments(d.ctx)
	if err != nil {
		t.Fatal(err)
	}
	var res *admin.ExperimentResult
	for i := range all {
		if all[i].ID == e.ID {
			res = &all[i]
		}
	}
	if res == nil || !res.Active || len(res.Arms) != 2 {
		t.Fatalf("the panel's test: %+v", res)
	}
	c, r := res.Arms[0], res.Arms[1]
	if c.ID != control.ID || r.ID != richer.ID {
		t.Fatalf("arms out of order: %s, %s", c.ID, r.ID)
	}
	// The fresh lord was counted by the badges and is in one of the two arms.
	if c.Exposed+r.Exposed != 25 {
		t.Fatalf("lords shown: %d + %d; want 25", c.Exposed, r.Exposed)
	}
	if c.Converted != 1 || r.Converted != 1 {
		t.Fatalf("conversions: control %d, richer %d; want one each (the sandbox buy is not counted)", c.Converted, r.Converted)
	}
	if c.RevenueCents != c.PriceCents || r.RevenueCents != r.PriceCents || r.PriceCents <= c.PriceCents {
		t.Fatalf("revenue: control %d of %d, richer %d of %d", c.RevenueCents, c.PriceCents, r.RevenueCents, r.PriceCents)
	}
	if c.ConversionBP != 10000/c.Exposed || c.Z != 0 {
		t.Fatalf("the control's figures: %+v", c)
	}
	if r.Significant {
		t.Fatalf("one buyer a side is called significant: z %.2f", r.Z)
	}
}
