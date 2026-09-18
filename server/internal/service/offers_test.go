package service

import (
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func offerIDs(list []*gameconfig.Product) string {
	ids := make([]string, 0, len(list))
	for _, pr := range list {
		ids = append(ids, pr.ID)
	}
	sort.Strings(ids)
	return strings.Join(ids, ",")
}

func shownOf(d Deps, ids ...string) shownOffers {
	rows := make([]sqlcdb.AppPlayerOffer, 0, len(ids))
	for _, id := range ids {
		rows = append(rows, sqlcdb.AppPlayerOffer{ProductID: id})
	}
	return d.shownFrom(rows)
}

// A lord is shown one Founder's Crate: the control while the test is off,
// their own arm while it runs, and never a second one when the test is
// switched on or off after they had theirs.
func TestAnOfferSlotIsShownOnce(t *testing.T) {
	d := Deps{Config: dealsConfig(t), ShopSecret: []byte("offers-test")}
	e := &d.Config.Commerce.Experiments[0]
	if e.ID != "starter_price" || len(e.Arms) != 2 {
		t.Fatalf("the seed's test changed: %+v", e)
	}
	control, richer := e.Arms[0].Product, e.Arms[1].Product

	lord := func(i int) sqlcdb.AppPlayer {
		return sqlcdb.AppPlayer{ID: uuid.NewSHA1(uuid.NameSpaceOID, []byte(fmt.Sprint("lord", i))), Level: 8}
	}

	e.Active = false
	for i := 0; i < 20; i++ {
		fire, lapse := d.levelOffersDue(lord(i), shownOf(d))
		if offerIDs(fire) != control || len(lapse) != 0 {
			t.Fatalf("test off, lord %d: fire %s, lapse %s; want only %s", i, offerIDs(fire), offerIDs(lapse), control)
		}
	}

	e.Active = true
	seen := map[string]int{}
	for i := 0; i < 40; i++ {
		p := lord(i)
		fire, _ := d.levelOffersDue(p, shownOf(d))
		want := d.armOf(p.ID, e).Product
		if offerIDs(fire) != want {
			t.Fatalf("test on, lord %d: fire %s; want their arm %s", i, offerIDs(fire), want)
		}
		seen[want]++
		// Already had the other arm (the test was off, or has since been switched
		// off): nothing more from the slot.
		other := control
		if want == control {
			other = richer
		}
		if fire, _ := d.levelOffersDue(p, shownOf(d, other)); len(fire) != 0 {
			t.Fatalf("lord %d, having had %s, was shown %s too", i, other, offerIDs(fire))
		}
		if fire, _ := d.levelOffersDue(p, shownOf(d, want)); len(fire) != 0 {
			t.Fatalf("lord %d was shown %s twice", i, want)
		}
	}
	if seen[control] == 0 || seen[richer] == 0 {
		t.Fatalf("40 lords all in one arm: %v", seen)
	}
}

// A lord past several level offers at once is shown the crate and the best
// one; the ones passed over lapse, and nothing already shown is touched.
func TestLevelOffersBeyondTheFirst(t *testing.T) {
	d := Deps{Config: dealsConfig(t), ShopSecret: []byte("offers-test")}
	d.Config.Commerce.Experiments[0].Active = false
	p := sqlcdb.AppPlayer{ID: uuid.New(), Level: 30}

	fire, lapse := d.levelOffersDue(p, shownOf(d))
	if offerIDs(fire) != "offer_l30,starter" || offerIDs(lapse) != "offer_l10,offer_l20" {
		t.Fatalf("a fresh level 30: fire %s, lapse %s", offerIDs(fire), offerIDs(lapse))
	}
	fire, lapse = d.levelOffersDue(p, shownOf(d, "starter", "offer_l10"))
	if offerIDs(fire) != "offer_l30" || offerIDs(lapse) != "offer_l20" {
		t.Fatalf("having had the crate and the level 10 offer: fire %s, lapse %s", offerIDs(fire), offerIDs(lapse))
	}
	fire, lapse = d.levelOffersDue(p, shownOf(d, "starter", "offer_l10", "offer_l20", "offer_l30"))
	if len(fire)+len(lapse) != 0 {
		t.Fatalf("everything shown, still due: fire %s, lapse %s", offerIDs(fire), offerIDs(lapse))
	}
	if fire, _ := d.levelOffersDue(sqlcdb.AppPlayer{ID: uuid.New(), Level: 7}, shownOf(d)); len(fire) != 0 {
		t.Fatalf("a level 7 lord was offered %s", offerIDs(fire))
	}
}
