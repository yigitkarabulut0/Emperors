//go:build integration

package itest

import (
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
)

// desk is the panel's billing desk over a store's world, with a real admin of
// each role so every action's audit row has someone to name.
type desk struct {
	*store
	svc             *admin.Service
	owner, des, mod *admin.Identity
}

func newDesk(t *testing.T) *desk {
	t.Helper()
	s := newStore(t)
	d := &desk{store: s, svc: &admin.Service{
		Pool: pool, Config: gameconfig.NewStore(s.d.Config, nil, nil), Billing: s.d,
	}}
	for _, role := range []string{"owner", "designer", "moderator"} {
		u, err := s.q.CreateAdminUser(s.ctx, sqlcdb.CreateAdminUserParams{
			Username: "it" + uuid.NewString()[:8], PasswordHash: "x", Role: role,
		})
		if err != nil {
			t.Fatal(err)
		}
		id := &admin.Identity{ID: u.ID, Username: u.Username, Role: role}
		switch role {
		case "owner":
			d.owner = id
		case "designer":
			d.des = id
		default:
			d.mod = id
		}
	}
	return d
}

func (d *desk) summary() *admin.BillingSummary {
	d.t.Helper()
	v, err := d.svc.BillingSummary(d.ctx, 30)
	if err != nil {
		d.t.Fatal(err)
	}
	return v
}

// The takings are Production's alone: a Sandbox purchase is counted beside
// them, and a refund comes off the day it was made.
func TestTheDeskCountsProductionOnly(t *testing.T) {
	d := newDesk(t)
	p := d.player(10, 0)
	before := d.summary()

	sandbox, _ := d.txn(p, "gems.330", "", nil)
	if _, err := d.d.VerifyApple(d.ctx, p.ID, sandbox); err != nil {
		t.Fatal(err)
	}
	real, realID := d.txn(p, "gems.60", "", map[string]any{"environment": iap.EnvProduction})
	if _, err := d.d.VerifyApple(d.ctx, p.ID, real); err != nil {
		t.Fatal(err)
	}
	after := d.summary()
	if got := after.GrossCents - before.GrossCents; got != 99 {
		t.Fatalf("takings rose by %d cents; want 99 (the Sandbox 4.99 is not revenue)", got)
	}
	if got := after.SandboxPurchases - before.SandboxPurchases; got != 1 {
		t.Fatalf("%d Sandbox purchases counted; want 1", got)
	}
	if got := after.Purchases - before.Purchases; got != 1 {
		t.Fatalf("%d Production purchases counted; want 1", got)
	}
	var found bool
	for _, pr := range after.Products {
		if pr.ProductID == "gems_60" {
			found = pr.Name != "" && pr.Name != pr.ProductID
		}
		if pr.ProductID == "gems_330" {
			t.Fatal("a Sandbox-only product is listed in the takings")
		}
	}
	if !found {
		t.Fatal("the pack bought in Production is not in the takings by product, with its title")
	}
	// Conversion and revenue per lord-day come from the days lords played.
	d.exec(`INSERT INTO app.player_days (player_id, day) VALUES ($1, current_date) ON CONFLICT DO NOTHING`, p.ID)
	s := d.summary()
	if s.ActiveLords < 1 || s.ConversionBP != s.Payers*10000/s.ActiveLords {
		t.Fatalf("conversion %d bp from %d payers over %d lords", s.ConversionBP, s.Payers, s.ActiveLords)
	}
	if s.NetCents > 0 && s.ARPDAUCentiCents <= 0 {
		t.Fatalf("revenue per lord-day is %d with %d cents net", s.ARPDAUCentiCents, s.NetCents)
	}
	if n := len(after.Daily); n != 30 {
		t.Fatalf("the daily series has %d days; want 30, empty days included", n)
	}
	if last := after.Daily[len(after.Daily)-1]; last.GrossCents < 99 {
		t.Fatalf("today's takings read %d cents", last.GrossCents)
	}

	d.notify(iap.NotifyRefund, "", real)
	refunded := d.summary()
	if got := refunded.RefundCents - after.RefundCents; got != 99 {
		t.Fatalf("refunds rose by %d cents; want 99", got)
	}
	if got := refunded.NetCents - before.NetCents; got != 0 {
		t.Fatalf("net moved by %d after buying and refunding the same pack", got)
	}

	// The list labels each; the filter finds the Sandbox one alone.
	rows, err := d.svc.Transactions(d.ctx, admin.TxnFilter{PlayerID: &p.ID})
	if err != nil || len(rows) != 2 {
		t.Fatalf("the lord's purchases: %d rows (%v); want 2", len(rows), err)
	}
	for _, r := range rows {
		if r.Sandbox != (r.Environment == iap.EnvSandbox) {
			t.Fatalf("%s is labelled sandbox=%v in %s", r.TransactionID, r.Sandbox, r.Environment)
		}
		if r.TransactionID == realID && r.State != "refunded" {
			t.Fatalf("the refunded purchase reads %s", r.State)
		}
		if r.Username != p.Username {
			t.Fatalf("a purchase names %q, want %q", r.Username, p.Username)
		}
	}
	sb, err := d.svc.Transactions(d.ctx, admin.TxnFilter{PlayerID: &p.ID, Environment: iap.EnvSandbox})
	if err != nil || len(sb) != 1 || !sb[0].Sandbox {
		t.Fatalf("the Sandbox filter found %d rows (%v)", len(sb), err)
	}
	byID, err := d.svc.Transactions(d.ctx, admin.TxnFilter{Search: realID})
	if err != nil || len(byID) != 1 || byID[0].TransactionID != realID {
		t.Fatalf("searching by transaction id found %d rows (%v)", len(byID), err)
	}
	if _, err := d.svc.Transactions(d.ctx, admin.TxnFilter{State: "stolen"}); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("an unknown state filter: %v", err)
	}
}

// Taking a purchase back from the panel takes back exactly what Apple's refund
// would have, once, and only a designer may, with a reason.
func TestTheDeskTakesBackAPurchase(t *testing.T) {
	d := newDesk(t)
	p := d.player(10, 0)
	_, id := d.buy(p, "gems.330") // 660: the first pack doubled
	if got := d.reload(p.ID).Diamonds; got != 660 {
		t.Fatalf("the pack paid %d", got)
	}

	if _, err := d.svc.TakeBack(d.ctx, d.mod, id, "refunded", "notice lost"); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator took a purchase back: %v", err)
	}
	if _, err := d.svc.TakeBack(d.ctx, d.des, id, "refunded", "  "); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("a take-back without a reason: %v", err)
	}
	if _, err := d.svc.TakeBack(d.ctx, d.des, id, "lost", "why"); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("a take-back to an unknown state: %v", err)
	}
	out, err := d.svc.TakeBack(d.ctx, d.des, id, "refunded", "Apple refunded it; the notice never came")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "took back 660") {
		t.Fatalf("the desk reported %q", out)
	}
	q := d.reload(p.ID)
	if q.Diamonds != 0 || q.VipPoints != 0 {
		t.Fatalf("after the take-back: %d diamonds, favour %d", q.Diamonds, q.VipPoints)
	}
	var state, note string
	if err := pool.QueryRow(d.ctx, `SELECT state, refund_note FROM app.iap_transactions WHERE transaction_id = $1`,
		id).Scan(&state, &note); err != nil {
		t.Fatal(err)
	}
	if state != "refunded" || !strings.Contains(note, d.des.Username) || !strings.Contains(note, "never came") {
		t.Fatalf("the transaction reads %s, %q", state, note)
	}
	// Apple's own refund arriving after it takes nothing more.
	if again, err := d.svc.TakeBack(d.ctx, d.owner, id, "revoked", "twice"); err != nil || again != "already refunded" {
		t.Fatalf("a second take-back: %q, %v", again, err)
	}
	if _, err := d.svc.TakeBack(d.ctx, d.des, "no-such-transaction", "revoked", "why"); err == nil {
		t.Fatal("a take-back of a transaction nobody holds succeeded")
	}
	var audits int
	_ = pool.QueryRow(d.ctx, `SELECT count(*) FROM admin.audit_log WHERE action = 'billing.take_back' AND subject = $1`,
		id).Scan(&audits)
	if audits != 1 {
		t.Fatalf("%d audit rows for one take-back", audits)
	}
}

// A notification stored and never acted on -- the server died between the two,
// or its retries ran out -- is acted on when the desk says so, once.
func TestTheDeskRetriesANotification(t *testing.T) {
	d := newDesk(t)
	p := d.player(10, 0)
	signed, id := d.txn(p, "gems.60", "", nil)
	if _, err := d.d.VerifyApple(d.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	payload, err := d.chain.Sign(map[string]any{
		"notificationType": iap.NotifyRefund, "notificationUUID": uuid.NewString(), "version": "2.0",
		"signedDate": d.now.UnixMilli(),
		"data":       map[string]any{"bundleId": bundleID, "environment": iap.EnvSandbox, "signedTransactionInfo": signed},
	})
	if err != nil {
		t.Fatal(err)
	}
	nid, err := d.q.InsertIAPNotification(d.ctx, sqlcdb.InsertIAPNotificationParams{
		NotificationUuid: uuid.NewString(), Type: iap.NotifyRefund, Environment: iap.EnvSandbox,
		TransactionID: &id, SignedPayload: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	// Received four days ago: past the job's 72 hours, so only the desk can act.
	d.exec(`UPDATE app.iap_notifications SET received_at = now() - interval '96 hours' WHERE id = $1`, nid)
	open, err := d.svc.Notifications(d.ctx, true, 100)
	if err != nil {
		t.Fatal(err)
	}
	status := ""
	for _, n := range open {
		if n.ID == nid {
			status = n.Status
		}
	}
	if status != "abandoned" {
		t.Fatalf("the four-day-old notification is %q; want abandoned", status)
	}

	out, err := d.svc.RetryNotification(d.ctx, d.mod, nid)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out, "refunded") {
		t.Fatalf("the retry reported %q", out)
	}
	if got := d.reload(p.ID).Diamonds; got != 0 {
		t.Fatalf("the retried refund left %d diamonds", got)
	}
	if again, err := d.svc.RetryNotification(d.ctx, d.mod, nid); err != nil || again != "already processed" {
		t.Fatalf("a second retry: %q, %v", again, err)
	}
	all, _ := d.svc.Notifications(d.ctx, false, 100)
	for _, n := range all {
		if n.ID == nid && (n.Status != "done" || n.ProcessedAt == nil) {
			t.Fatalf("after the retry the notification is %s", n.Status)
		}
	}
	if _, err := d.svc.RetryNotification(d.ctx, d.mod, 1<<40); err == nil {
		t.Fatal("a retry of a notification nobody holds succeeded")
	}
	if _, err := (&admin.Service{Pool: pool, Config: d.svc.Config}).RetryNotification(d.ctx, d.mod, nid); !errors.Is(err, admin.ErrUnavailable) {
		t.Fatalf("a desk with no billing hands: %v", err)
	}
}

// A forgiven debt is gone and the ledger still reconciles, with the whole
// debt recorded as forgiven and nothing reaching the purse.
func TestTheDeskForgivesADebt(t *testing.T) {
	d := newDesk(t)
	p := d.player(12, 0)
	signed, _ := d.txn(p, "gems.330", "", nil)
	if _, err := d.d.VerifyApple(d.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	p = d.reload(p.ID)
	if _, err := d.d.BuyCosmetic(d.ctx, p.ID, "frame_laurel", p.ActionSeq+1); err != nil {
		t.Fatal(err)
	}
	d.notify(iap.NotifyRefund, "", signed)
	if got := d.reload(p.ID).DiamondDebt; got != 250 {
		t.Fatalf("the debt is %d, want 250", got)
	}

	if _, err := d.svc.ForgiveDebt(d.ctx, d.mod, p.ID, "goodwill"); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator forgave a debt: %v", err)
	}
	if _, err := d.svc.ForgiveDebt(d.ctx, d.des, p.ID, ""); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("forgiving without a reason: %v", err)
	}
	row, err := d.svc.ForgiveDebt(d.ctx, d.des, p.ID, "goodwill after a billing mix-up")
	if err != nil {
		t.Fatal(err)
	}
	q := d.reload(p.ID)
	if q.DiamondDebt != 0 || q.Diamonds != 0 || row.Diamonds != 0 {
		t.Fatalf("after forgiving: %d diamonds, %d owed", q.Diamonds, q.DiamondDebt)
	}
	var delta, gross, debt int64
	var reason string
	if err := pool.QueryRow(d.ctx, `SELECT delta, gross, debt_after, reason FROM app.diamond_ledger
		WHERE player_id = $1 ORDER BY id DESC LIMIT 1`, p.ID).Scan(&delta, &gross, &debt, &reason); err != nil {
		t.Fatal(err)
	}
	if reason != "debt_forgiven" || delta != 0 || gross != 250 || debt != 0 {
		t.Fatalf("the ledger row: %s delta %d gross %d debt %d; want debt_forgiven 0, 250, 0", reason, delta, gross, debt)
	}
	if _, err := d.svc.ForgiveDebt(d.ctx, d.des, p.ID, "again"); !errors.Is(err, admin.ErrNothingToDo) {
		t.Fatalf("forgiving a debt already forgiven: %v", err)
	}
}

// A lord's billing page shows what their money left on them.
func TestTheDeskShowsALordsPurchases(t *testing.T) {
	d := newDesk(t)
	p := d.player(10, 0)
	steward, _ := d.txn(p, "comfort.steward", "", map[string]any{"type": iap.TypeNonConsumable,
		"environment": iap.EnvProduction})
	if _, err := d.d.VerifyApple(d.ctx, p.ID, steward); err != nil {
		t.Fatal(err)
	}
	d.buy(p, "gems.60")
	d.buy(p, "gems.60")

	v, err := d.svc.PlayerBilling(d.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !v.Steward || len(v.Entitlements) != 1 || v.Entitlements[0].Name != "steward" {
		t.Fatalf("the Steward: owned %v, entitlements %+v", v.Steward, v.Entitlements)
	}
	if v.SpentCents != 499 || v.Purchases != 1 || v.SandboxPurchases != 2 {
		t.Fatalf("spend %d over %d Production and %d Sandbox purchases; want 499, 1, 2",
			v.SpentCents, v.Purchases, v.SandboxPurchases)
	}
	if v.VIPPoints != 499+99+99 || v.VIPLevel != 2 || v.VIPNextAt != 999 {
		t.Fatalf("favour %d, level %d, next at %d; want 697, 2, 999", v.VIPPoints, v.VIPLevel, v.VIPNextAt)
	}
	counts := map[string]int32{}
	for _, b := range v.Bought {
		counts[b.ProductID] = b.Count
	}
	stewardID := d.d.Config.ProductByStoreID("com.emperors.game.comfort.steward").ID
	if counts["gems_60"] != 2 || counts[stewardID] != 1 {
		t.Fatalf("bought %v", counts)
	}
	if len(v.Transactions) != 3 {
		t.Fatalf("%d transactions on the page, want 3", len(v.Transactions))
	}
	if _, err := d.svc.PlayerBilling(d.ctx, uuid.New()); !errors.Is(err, admin.ErrNotFound) {
		t.Fatalf("a lord nobody knows: %v", err)
	}
}

// A lasting right given by hand works like a bought one, is taken back only by
// hand, and never touches one a purchase gave.
func TestTheDeskGivesALastingRight(t *testing.T) {
	d := newDesk(t)
	p := d.player(10, 0)
	bagBefore := d.reload(p.ID).BagBonus

	if _, err := d.svc.GrantEntitlement(d.ctx, d.mod, p.ID, "quartermaster", "support"); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator gave a lasting right: %v", err)
	}
	if _, err := d.svc.GrantEntitlement(d.ctx, d.des, p.ID, "quartermaster", " "); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("giving without a reason: %v", err)
	}
	if _, err := d.svc.GrantEntitlement(d.ctx, d.des, p.ID, "dragon", "support"); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("giving a right nobody sells: %v", err)
	}
	v, err := d.svc.GrantEntitlement(d.ctx, d.des, p.ID, "quartermaster", "lost in a restore")
	if err != nil {
		t.Fatal(err)
	}
	if v.BagBonus <= bagBefore || d.reload(p.ID).BagBonus != v.BagBonus || len(v.Entitlements) != 1 ||
		!strings.HasPrefix(v.Entitlements[0].TransactionID, "admin:") {
		t.Fatalf("after giving the Quartermaster: bag +%d, %+v", v.BagBonus, v.Entitlements)
	}
	inv, err := d.d.GetInventory(d.ctx, p.ID)
	if err != nil || inv.Cap != d.d.Config.Items.InventoryCap+int64(v.BagBonus) {
		t.Fatalf("the bag after the Quartermaster: %+v, %v", inv, err)
	}
	if _, err := d.svc.GrantEntitlement(d.ctx, d.des, p.ID, "quartermaster", "again"); !errors.Is(err, admin.ErrNothingToDo) {
		t.Fatalf("giving a right already held: %v", err)
	}

	// Taken back by hand, the room goes.
	v, err = d.svc.RevokeEntitlement(d.ctx, d.des, p.ID, "quartermaster", "given to the wrong lord")
	if err != nil || v.BagBonus != 0 || len(v.Entitlements) != 0 {
		t.Fatalf("after taking it back: %+v, %v", v, err)
	}

	// One a purchase gave is not the panel's to take.
	signed, _ := d.txn(p, "comfort.steward", "", map[string]any{"type": iap.TypeNonConsumable})
	if _, err := d.d.VerifyApple(d.ctx, p.ID, signed); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.RevokeEntitlement(d.ctx, d.des, p.ID, "steward", "tidy"); !errors.Is(err, admin.ErrNothingToDo) {
		t.Fatalf("the panel took back a bought Steward: %v", err)
	}
	if !d.reload(p.ID).StewardOwned {
		t.Fatal("the bought Steward was lost")
	}
	var audits int
	_ = pool.QueryRow(d.ctx, `SELECT count(*) FROM admin.audit_log WHERE subject = $1 AND action LIKE 'player.entitlement_%'`,
		p.ID.String()).Scan(&audits)
	if audits != 2 {
		t.Fatalf("audit rows: %d, want the grant and the revoke", audits)
	}
}
