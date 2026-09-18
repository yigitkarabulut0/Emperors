//go:build integration

package itest

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/iap/iaptest"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

const bundleID = "com.emperors.game"

// store is a world with an App Store: purchases signed under a throwaway chain
// the service trusts.
type store struct {
	*world
	chain *iaptest.Chain
	n     int
}

func newStore(t *testing.T) *store {
	t.Helper()
	w := newWorld(t)
	c, err := iaptest.New(iaptest.Options{})
	if err != nil {
		t.Fatal(err)
	}
	w.d.IAP = &iap.Verifier{Root: c.Root, BundleID: bundleID, AllowSandbox: true}
	return &store{world: w, chain: c}
}

// txn signs a purchase of one product for one lord. orig "" starts a new chain.
func (s *store) txn(p sqlcdb.AppPlayer, product, orig string, extra map[string]any) (string, string) {
	s.t.Helper()
	s.n++
	id := fmt.Sprintf("2%015d", time.Now().UnixNano()%1_000_000_000_000+int64(s.n))
	if orig == "" {
		orig = id
	}
	at := s.now.UnixMilli()
	payload := map[string]any{
		"transactionId": id, "originalTransactionId": orig, "bundleId": bundleID,
		"productId": "com.emperors.game." + product, "purchaseDate": at, "originalPurchaseDate": at,
		"quantity": 1, "type": iap.TypeConsumable, "appAccountToken": p.ID.String(),
		"inAppOwnershipType": "PURCHASED", "signedDate": at, "environment": iap.EnvSandbox,
		"price": 9990, "currency": "USD", "storefront": "TUR",
	}
	for k, v := range extra {
		payload[k] = v
	}
	signed, err := s.chain.Sign(payload)
	if err != nil {
		s.t.Fatal(err)
	}
	return signed, id
}

// notify signs and sends one notification carrying a transaction.
func (s *store) notify(kind, subtype, signedTxn string) {
	s.t.Helper()
	payload := map[string]any{
		"notificationType": kind, "subtype": subtype, "notificationUUID": uuid.NewString(),
		"version": "2.0", "signedDate": s.now.UnixMilli(),
		"data": map[string]any{"bundleId": bundleID, "environment": iap.EnvSandbox,
			"signedTransactionInfo": signedTxn},
	}
	signed, err := s.chain.Sign(payload)
	if err != nil {
		s.t.Fatal(err)
	}
	if err := s.d.AppleNotify(s.ctx, signed); err != nil {
		s.t.Fatalf("%s notification: %v", kind, err)
	}
}

func (s *store) buy(p sqlcdb.AppPlayer, product string) (*service.Delivery, string) {
	s.t.Helper()
	signed, id := s.txn(p, product, "", nil)
	del, err := s.d.VerifyApple(s.ctx, p.ID, signed)
	if err != nil {
		s.t.Fatalf("buy %s: %v", product, err)
	}
	return del, id
}

// A pack is delivered once however often it is sent, and its first purchase
// pays double.
func TestAPackIsDeliveredOnce(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	signed, _ := s.txn(p, "gems.700", "", nil)

	del, err := s.d.VerifyApple(s.ctx, p.ID, signed)
	if err != nil {
		t.Fatal(err)
	}
	if !del.FirstBonus || s.reload(p.ID).Diamonds != 1400 {
		t.Fatalf("the first 700 pack: bonus %v, purse %d; want doubled to 1400", del.FirstBonus, s.reload(p.ID).Diamonds)
	}
	again, err := s.d.VerifyApple(s.ctx, p.ID, signed)
	if err != nil || !again.Already || s.reload(p.ID).Diamonds != 1400 {
		t.Fatalf("the same transaction again: %+v %v, purse %d", again, err, s.reload(p.ID).Diamonds)
	}
	// Apple's notification of the same purchase delivers nothing more either.
	s.notify(iap.NotifyOneTimeCharge, "", signed)
	if got := s.reload(p.ID).Diamonds; got != 1400 {
		t.Fatalf("the notification of a delivered purchase paid again: %d", got)
	}
	// A second purchase of the pack is not doubled.
	s.buy(p, "gems.700")
	if got := s.reload(p.ID).Diamonds; got != 2100 {
		t.Fatalf("a second 700 pack left %d, want 2100", got)
	}
	var cents int64
	if err := pool.QueryRow(s.ctx, `SELECT vip_points FROM app.players WHERE id = $1`, p.ID).Scan(&cents); err != nil || cents != 1998 {
		t.Fatalf("royal favour after two 9.99 packs: %d (%v)", cents, err)
	}
}

// A purchase is refused for anyone but the lord it was bought for.
func TestAPurchaseBelongsToItsBuyer(t *testing.T) {
	s := newStore(t)
	buyer, other := s.player(10, 0), s.player(10, 0)
	signed, _ := s.txn(buyer, "gems.60", "", nil)
	// Another lord's session sending it (two lords on one phone) delivers it to
	// the lord who bought it, and says so: the phone may finish it.
	del, err := s.d.VerifyApple(s.ctx, other.ID, signed)
	if err != nil || !del.ForAnother {
		t.Fatalf("another lord sending the purchase: %+v, %v", del, err)
	}
	if got := s.reload(buyer.ID).Diamonds; got != 120 {
		t.Fatalf("the buyer received %d diamonds, want 120 (60, doubled the first time)", got)
	}
	if got := s.reload(other.ID).Diamonds; got != 0 {
		t.Fatalf("the lord who only sent it received %d diamonds", got)
	}
	if del.Snapshot == nil || del.Snapshot.Player.ID != other.ID.String() {
		t.Fatal("the answer carries a snapshot other than the sender's own")
	}
	// Sent again by the buyer, it is the same purchase, already delivered.
	if again, err := s.d.VerifyApple(s.ctx, buyer.ID, signed); err != nil || !again.Already || again.ForAnother {
		t.Fatalf("the buyer sending it after: %+v, %v", again, err)
	}
	// A buyer who has deleted their account can receive nothing: refused for good.
	gone := s.player(10, 0)
	lost, _ := s.txn(gone, "gems.60", "", nil)
	s.exec(`DELETE FROM app.players WHERE id = $1`, gone.ID)
	if _, err := s.d.VerifyApple(s.ctx, other.ID, lost); !errors.Is(err, service.ErrIAPOwnedByAnother) {
		t.Fatalf("a purchase whose buyer is gone: %v", err)
	}
	// A restore of a lasting right on another account is refused too.
	steward, _ := s.txn(buyer, "comfort.steward", "", map[string]any{"type": iap.TypeNonConsumable, "appAccountToken": ""})
	if _, err := s.d.VerifyApple(s.ctx, buyer.ID, steward); err != nil {
		t.Fatal(err)
	}
	res, err := s.d.RestoreApple(s.ctx, other.ID, []string{steward})
	if err != nil || len(res.Restored) != 0 || len(res.Refused) != 1 {
		t.Fatalf("restoring the buyer's Steward on another account: %+v %v", res, err)
	}
	if s.reload(other.ID).StewardOwned {
		t.Fatal("the Steward went to a lord who did not buy it")
	}
	// An unknown product is not recorded, so the phone keeps it for later.
	unknown, _ := s.txn(buyer, "gems.999999", "", nil)
	if _, err := s.d.VerifyApple(s.ctx, buyer.ID, unknown); !errors.Is(err, service.ErrIAPUnknownProduct) {
		t.Fatalf("an unknown product: %v", err)
	}
}

// Money is never refused at the moment of grant: a cosmetic already owned pays
// the product's fallback diamonds instead.
func TestAnOwnedCosmeticPaysItsFallback(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	s.buy(p, "starter.299")
	if got := s.reload(p.ID).Diamonds; got != 300 {
		t.Fatalf("the Founder's Crate paid %d diamonds, want 300", got)
	}
	var potions int64
	_ = pool.QueryRow(s.ctx, `SELECT qty FROM app.player_tokens WHERE player_id = $1 AND token = 'energy_potion'`, p.ID).Scan(&potions)
	if potions != 3 {
		t.Fatalf("potions %d, want 3", potions)
	}
	// Bought again (two phones at once): the frame and title are owned, so
	// each pays 100 diamonds, ledgered against this purchase.
	s.buy(p, "starter.299")
	if got := s.reload(p.ID).Diamonds; got != 300+300+200 {
		t.Fatalf("a second crate left %d diamonds, want 800", got)
	}
}

// A refund takes back what the purchase gave; what was spent becomes a debt
// paid first out of the next diamonds earned.
func TestARefundTakesBackAndLeavesADebt(t *testing.T) {
	s := newStore(t)
	p := s.player(12, 0)
	signed, _ := s.txn(p, "gems.330", "", nil)
	if _, err := s.d.VerifyApple(s.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	// 660 (first purchase doubled), of which 250 spent on a frame.
	p = s.reload(p.ID)
	if _, err := s.d.BuyCosmetic(s.ctx, p.ID, "frame_laurel", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	s.notify(iap.NotifyRefund, "", signed)
	p = s.reload(p.ID)
	if p.Diamonds != 0 || p.DiamondDebt != 250 || p.VipPoints != 0 {
		t.Fatalf("after the refund: %d diamonds, debt %d, favour %d; want 0, 250, 0", p.Diamonds, p.DiamondDebt, p.VipPoints)
	}
	var state string
	_ = pool.QueryRow(s.ctx, `SELECT state FROM app.iap_transactions WHERE player_id = $1`, p.ID).Scan(&state)
	if state != "refunded" {
		t.Fatalf("the transaction reads %q after the refund", state)
	}
	// The same refund notified twice takes nothing more.
	s.notify(iap.NotifyRefund, "", signed)
	if got := s.reload(p.ID).DiamondDebt; got != 250 {
		t.Fatalf("a second refund notice moved the debt to %d", got)
	}
	// The next diamonds earned repay the debt first.
	if _, err := s.d.ClaimDaily(s.ctx, p.ID, ""); err != nil {
		t.Fatal(err)
	}
	first := s.d.Config.Retention.Calendar.Squares[0].Grant.Diamonds
	if p = s.reload(p.ID); p.Diamonds != 0 || p.DiamondDebt != 250-first {
		t.Fatalf("after the day's %d diamonds: %d held, %d owed; want 0 and %d", first, p.Diamonds, p.DiamondDebt, 250-first)
	}
}

// A refund of a lasting right revokes it.
func TestARefundedStewardLeaves(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	signed, _ := s.txn(p, "comfort.quartermaster", "", map[string]any{"type": iap.TypeNonConsumable})
	if _, err := s.d.VerifyApple(s.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	if got := s.reload(p.ID).BagBonus; got != 50 {
		t.Fatalf("the Quartermaster added %d slots, want 50", got)
	}
	// 150, the Quartermaster's 50, and Royal Favour II's 5 (the 4.99 reached it).
	inv, err := s.d.GetInventory(s.ctx, p.ID)
	if err != nil || inv.Cap != 150+50+5 {
		t.Fatalf("the bag after the Quartermaster: %d (%v)", inv.Cap, err)
	}
	s.notify(iap.NotifyRefund, "", signed)
	if got := s.reload(p.ID).BagBonus; got != 0 {
		t.Fatalf("a refunded Quartermaster left %d slots", got)
	}
}

// The Royal Stipend pays now and a share each day, and a refund stops it and
// takes back every share claimed.
func TestTheStipendPaysDailyUntilRefunded(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	signed, _ := s.txn(p, "stipend.30", "", nil)
	if _, err := s.d.VerifyApple(s.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	if _, err := s.d.ClaimStipend(s.ctx, p.ID); err != nil {
		t.Fatalf("today's share: %v", err)
	}
	if _, err := s.d.ClaimStipend(s.ctx, p.ID); !errors.Is(err, service.ErrNothingToClaim) {
		t.Fatalf("today's share twice: %v", err)
	}
	s.now = s.now.Add(24 * time.Hour)
	if _, err := s.d.ClaimStipend(s.ctx, p.ID); err != nil {
		t.Fatalf("tomorrow's share: %v", err)
	}
	if got := s.reload(p.ID).Diamonds; got != 300+60+60 {
		t.Fatalf("after two shares: %d, want 420", got)
	}
	store, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil || !store.Stipend.Active || store.Stipend.DaysLeft != 29 {
		t.Fatalf("the stipend on its second day: %+v %v", store.Stipend, err)
	}
	s.notify(iap.NotifyRefund, "", signed)
	if got := s.reload(p.ID).Diamonds; got != 0 {
		t.Fatalf("a refunded stipend left %d diamonds", got)
	}
	s.now = s.now.Add(24 * time.Hour)
	if _, err := s.d.ClaimStipend(s.ctx, p.ID); !errors.Is(err, service.ErrNothingToClaim) {
		t.Fatalf("a share after the refund: %v", err)
	}
}

// Crown Patronage runs while its subscription does: a free refill, a bigger
// bag, and its diamonds each period.
func TestPatronageRunsWithItsSubscription(t *testing.T) {
	s := newStore(t)
	p := s.player(12, 0)
	expires := s.now.Add(30 * 24 * time.Hour)
	first, orig := s.txn(p, "patronage.month", "", map[string]any{
		"type": iap.TypeAutoRenewable, "expiresDate": expires.UnixMilli()})
	if _, err := s.d.VerifyApple(s.ctx, p.ID, first); err != nil {
		t.Fatal(err)
	}
	p = s.reload(p.ID)
	if p.PatronUntil == nil || !p.PatronUntil.Equal(expires.Truncate(time.Millisecond)) || p.Diamonds != 60 {
		t.Fatalf("a new patron: until %v, %d diamonds", p.PatronUntil, p.Diamonds)
	}
	// The day's first refill is free for a patron, and the day allows four.
	w := s.world
	w.exec(`UPDATE app.players SET energy_milli = 0, energy_updated_at = $2 WHERE id = $1`, p.ID, s.now)
	p = s.reload(p.ID)
	if _, err := s.d.BuyStoreGood(s.ctx, p.ID, "energy_refill", "", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	if got := s.reload(p.ID).Diamonds; got != 60 {
		t.Fatalf("a patron's first refill cost %d diamonds", 60-got)
	}
	// 150, the patron's 25, and Royal Favour II's 5 (the 6.99 reached it).
	if inv, _ := s.d.GetInventory(s.ctx, p.ID); inv.Cap != 150+25+5 {
		t.Fatalf("a patron's bag holds %d, want 180", inv.Cap)
	}

	// A renewal is its own transaction on the same chain: another period paid.
	renewed := expires.Add(30 * 24 * time.Hour)
	next, _ := s.txn(p, "patronage.month", orig, map[string]any{
		"type": iap.TypeAutoRenewable, "expiresDate": renewed.UnixMilli()})
	s.notify(iap.NotifyDidRenew, "", next)
	p = s.reload(p.ID)
	if !p.PatronUntil.Equal(renewed.Truncate(time.Millisecond)) || p.Diamonds != 120 {
		t.Fatalf("after the renewal: until %v, %d diamonds", p.PatronUntil, p.Diamonds)
	}
	w.exec(`UPDATE app.players SET cos_frame = 'frame_patron' WHERE id = $1`, p.ID)
	if snap, _ := s.d.GetState(s.ctx, p.ID); snap.Player.Worn.Frame != "frames/patron" {
		t.Fatalf("a patron wearing the patron's frame reads %q", snap.Player.Worn.Frame)
	}
	// Expiry ends it, and the frame goes with it.
	s.notify(iap.NotifyExpired, "VOLUNTARY", next)
	if p = s.reload(p.ID); p.PatronUntil != nil {
		t.Fatalf("an expired patronage still runs until %v", p.PatronUntil)
	}
	if snap, _ := s.d.GetState(s.ctx, p.ID); snap.Player.Worn.Frame != "" {
		t.Fatalf("a lapsed patron still wears %q", snap.Player.Worn.Frame)
	}
}

// Largesse reaches every lord of the buyer's kingdom who has been there a day,
// and a refund withdraws the letters nobody opened.
func TestLargesseReachesTheKingdom(t *testing.T) {
	s := newStore(t)
	buyer, old, fresh := s.player(20, 0), s.player(20, 0), s.player(20, 0)
	k, err := s.q.CreateKingdom(s.ctx, sqlcdb.CreateKingdomParams{Name: "It" + uuid.NewString()[:6], Tag: "I" + uuid.NewString()[:2], LeaderID: &buyer.ID})
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range []struct {
		id    uuid.UUID
		since time.Time
	}{{buyer.ID, s.now.Add(-72 * time.Hour)}, {old.ID, s.now.Add(-48 * time.Hour)}, {fresh.ID, s.now.Add(-time.Hour)}} {
		s.exec(`UPDATE app.players SET kingdom_id = $2, kingdom_role = 'member', kingdom_joined_at = $3 WHERE id = $1`, m.id, k.ID, m.since)
	}
	del, id := s.buy(s.reload(buyer.ID), "largesse")
	if got := s.reload(buyer.ID).Diamonds; got != 600 {
		t.Fatalf("the buyer received %d diamonds, want 600", got)
	}
	var reached int
	for _, l := range del.Lines {
		if l.Kind == "largesse" {
			reached = int(l.Amount)
		}
	}
	if reached != 1 {
		t.Fatalf("the Largesse reached %d lords, want the one who has been there a day", reached)
	}
	if n := s.count(`SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = 'largesse'`, fresh.ID); n != 0 {
		t.Fatal("a lord who joined an hour ago received the Largesse")
	}
	// And the hall is told who opened the coffers. The gift goes by letter --
	// that is the one way a reward is paid -- but a lord who spent real money on
	// their whole kingdom is named for it, which is what SysLargesse is for.
	if n := s.count(`SELECT count(*) FROM app.chat_messages
		WHERE kingdom_id = $1 AND system_kind = 'largesse'`, *buyer.KingdomID); n != 1 {
		t.Fatalf("the hall has %d lines about the Largesse, want one", n)
	}
	signed := ""
	_ = pool.QueryRow(s.ctx, `SELECT signed FROM app.iap_transactions WHERE transaction_id = $1`, id).Scan(&signed)
	s.notify(iap.NotifyRefund, "", signed)
	if n := s.count(`SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = 'largesse' AND deleted_at IS NULL`, old.ID); n != 0 {
		t.Fatal("a refunded Largesse's unopened letter stayed in the inbox")
	}
}

// Royal Favour's levels give their cosmetics, and a refund that drops a level
// takes them back.
func TestRoyalFavourRisesAndFalls(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	_, id := s.buy(p, "gems.700") // 999 cents: Royal Favour III
	if got := s.reload(p.ID).VipPoints; got != 999 {
		t.Fatalf("favour %d, want 999", got)
	}
	if n := s.count(`SELECT count(*) FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = 'color_azure'`, p.ID); n != 1 {
		t.Fatal("Royal Favour III did not bring its colour")
	}
	signed := ""
	_ = pool.QueryRow(s.ctx, `SELECT signed FROM app.iap_transactions WHERE transaction_id = $1`, id).Scan(&signed)
	s.notify(iap.NotifyRefund, "", signed)
	if n := s.count(`SELECT count(*) FROM app.player_cosmetics WHERE player_id = $1 AND cosmetic_id = 'color_azure'`, p.ID); n != 0 {
		t.Fatal("the colour outlived the favour that brought it")
	}
}

// A lord shown offers sees the crate and the best level offer they have
// reached, never a stack of them, and a bought offer leaves the shelf.
func TestOffersComeOneAtATime(t *testing.T) {
	s := newStore(t)
	p := s.player(40, 0)
	store, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	var offers []string
	for _, pr := range store.Products {
		if pr.Shelf == "offers" && pr.EndsIn > 0 {
			offers = append(offers, pr.ID)
		}
	}
	if len(offers) != 2 || !(contains(offers, "starter") && contains(offers, "offer_l30")) {
		t.Fatalf("a level-40 lord is offered %v, want the crate and the level-30 offer", offers)
	}
	b, _ := s.d.GetBadges(s.ctx, p.ID)
	if b.Offers != 2 || b.OffersUnseen != 2 {
		t.Fatalf("badges: %d offers, %d unseen", b.Offers, b.OffersUnseen)
	}
	if err := s.d.SeeOffers(s.ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	s.buy(p, "offer.l30")
	store, _ = s.d.GetCourtStore(s.ctx, p.ID)
	for _, pr := range store.Products {
		if pr.ID == "offer_l30" {
			t.Fatal("a bought offer is still on the shelf")
		}
	}
	// Tomorrow the crate's window has passed.
	s.now = s.now.Add(49 * time.Hour)
	store, _ = s.d.GetCourtStore(s.ctx, p.ID)
	for _, pr := range store.Products {
		if pr.ID == "starter" {
			t.Fatal("the crate is still offered after its 48 hours")
		}
	}
}

// A refund of a deleted account's purchase is settled as nothing to take back.
func TestARefundAfterDeletion(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	s.withPassword(p)
	_, id := s.buy(p, "gems.60")
	signed := ""
	_ = pool.QueryRow(s.ctx, `SELECT signed FROM app.iap_transactions WHERE transaction_id = $1`, id).Scan(&signed)
	if err := s.d.DeleteAccount(s.ctx, p.ID, itestPassword); err != nil {
		t.Fatal(err)
	}
	s.notify(iap.NotifyRefund, "", signed)
	var outcome string
	if err := pool.QueryRow(s.ctx, `SELECT outcome FROM app.iap_notifications WHERE transaction_id = $1`, id).Scan(&outcome); err != nil {
		t.Fatal(err)
	}
	if outcome != "refunded: the account was deleted; nothing to take back" {
		t.Fatalf("the refund's outcome: %q", outcome)
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// Crown Patronage says everything it gives, the looks worn while it lasts
// among them, so the store's card has nothing to leave out.
func TestThePatronageSaysWhatItWears(t *testing.T) {
	s := newStore(t)
	p := s.player(10, 0)
	v, err := s.d.GetCourtStore(s.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	pr := s.d.Config.Product("patronage")
	if pr == nil || pr.Patronage == nil || len(pr.Patronage.Cosmetics) == 0 {
		t.Fatal("the catalogue's patronage wears nothing")
	}
	for _, sp := range v.Products {
		if sp.ID != "patronage" {
			continue
		}
		// One line for the looks, naming each: the Favour painting has a row a
		// perk, five in all.
		var looks []string
		for _, l := range sp.Lines {
			if strings.HasSuffix(l.Text, "while it lasts") {
				looks = append(looks, l.Text)
			}
		}
		if len(looks) != 1 {
			t.Fatalf("the patronage's looks in %d lines, want one: %+v", len(looks), sp.Lines)
		}
		for _, id := range pr.Patronage.Cosmetics {
			if c := s.d.Config.Cosmetic(id); c == nil || !strings.Contains(looks[0], c.Name) {
				t.Fatalf("the looks line %q leaves out %s", looks[0], id)
			}
		}
		if strings.Contains(looks[0], "Gold,") || !strings.Contains(looks[0], "name colour") {
			t.Fatalf("the looks line %q could read as gold for sale", looks[0])
		}
		if len(sp.Lines) > 5 {
			t.Fatalf("the patronage says %d things; the painting has five rows", len(sp.Lines))
		}
		return
	}
	t.Fatal("the store does not list the patronage")
}
