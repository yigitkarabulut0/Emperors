package service

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func shopDeps(t *testing.T) Deps {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return Deps{Config: b, ShopSecret: []byte("test-shop-secret")}
}

// A reroll puts different items on the shelf. This is the fact the purchase
// mask has to respect: if the mask survives a reroll, a slot the player bought
// from goes on refusing to sell for the rest of the window while displaying an
// item nobody has bought. That shipped, and this is what makes it wrong.
func TestRerollChangesEveryOffer(t *testing.T) {
	d := shopDeps(t)
	pid := uuid.MustParse("11111111-2222-3333-4444-555555555555")

	before := d.rollOffers(pid, sqlcdb.AppShopState{WindowID: 4242, RerollIndex: 0}, 30, 0)
	after := d.rollOffers(pid, sqlcdb.AppShopState{WindowID: 4242, RerollIndex: 1}, 30, 0)

	if len(before) == 0 || len(before) != len(after) {
		t.Fatalf("shelves are %d and %d offers", len(before), len(after))
	}
	same := 0
	for i := range before {
		if before[i].Item.DefID == after[i].Item.DefID &&
			before[i].Item.QualityPct == after[i].Item.QualityPct {
			same++
		}
	}
	if same == len(before) {
		t.Fatal("a reroll left every slot holding the same item; it is not a reroll")
	}
}

// The same inputs must always give the same shelf, or a retried request would
// quietly reroll and a player could be charged for an item they never saw.
func TestTheShelfIsDeterministic(t *testing.T) {
	d := shopDeps(t)
	pid := uuid.MustParse("11111111-2222-3333-4444-555555555555")
	st := sqlcdb.AppShopState{WindowID: 99, RerollIndex: 2, LuckBp: 500}

	a := d.rollOffers(pid, st, 25, 0)
	b := d.rollOffers(pid, st, 25, 0)
	for i := range a {
		if a[i].Item.DefID != b[i].Item.DefID || a[i].Price != b[i].Price {
			t.Fatalf("slot %d differs between two rolls of the same window", i)
		}
	}
}

// The mask lives in SQL, which no test here has a database for, so the query
// itself is what gets held: bumping the reroll must clear what was bought.
func TestBumpRerollClearsThePurchaseMask(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "db", "queries", "shop.sql"))
	if err != nil {
		t.Fatal(err)
	}
	i := strings.Index(string(b), "-- name: BumpReroll")
	if i < 0 {
		t.Fatal("BumpReroll is gone from db/queries/shop.sql")
	}
	stmt := string(b)[i:]
	if j := strings.Index(stmt, ";"); j >= 0 {
		stmt = stmt[:j]
	}
	if !strings.Contains(stmt, "purchased_mask = 0") {
		t.Fatalf("BumpReroll no longer clears purchased_mask:\n%s", stmt)
	}
}
