package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// The billing desk: what the App Store sold, what it took back, and the few
// things support may do about a purchase.
//
// Revenue is Production alone. Sandbox purchases -- App Review, TestFlight, our
// own tests -- are listed with a SANDBOX label and counted beside the takings,
// never in them.

// Billing is the slice of the game service the desk acts through: the code
// Apple's notifications run, so a refund applied here takes back exactly what
// Apple's would have. Optional; nil answers ErrUnavailable.
type Billing interface {
	RetryNotification(ctx context.Context, id int64) (string, error)
	TakeBack(ctx context.Context, transactionID, state, note string) (string, error)
}

// ErrUnavailable is an action whose machinery this server was not given.
var ErrUnavailable = errors.New("purchases are not configured on this server")

// BillingSummary is the takings over a window.
type BillingSummary struct {
	Days             int   `json:"days"`
	GrossCents       int64 `json:"gross_cents"`
	RefundCents      int64 `json:"refund_cents"`
	NetCents         int64 `json:"net_cents"`
	Purchases        int64 `json:"purchases"`
	Refunds          int64 `json:"refunds"`
	Revoked          int64 `json:"revoked"`
	Payers           int64 `json:"payers"`
	ARPPUCents       int64 `json:"arppu_cents"`
	SandboxPurchases int64 `json:"sandbox_purchases"`
	SandboxCents     int64 `json:"sandbox_cents"`
	// Lords who played in the window, and net revenue per lord per day played
	// (ARPDAU, in hundredths of a cent so a small game still shows a figure).
	// Conversion is payers over those lords, in basis points.
	ActiveLords      int64 `json:"active_lords"`
	ARPDAUCentiCents int64 `json:"arpdau_centicents"`
	ConversionBP     int64 `json:"conversion_bp"`
	// Notifications waiting on a retry, and ones whose retries ran out.
	PendingNotices   int64            `json:"pending_notifications"`
	AbandonedNotices int64            `json:"abandoned_notifications"`
	Daily            []BillingDay     `json:"daily"`
	Products         []ProductTakings `json:"products"`
	Flagged          []RefundFlag     `json:"flagged"`
	FlagRefunds      int              `json:"flag_refunds"`
	FlagDays         int              `json:"flag_days"`
	// What the herald paid over the same window. Nil on a realm with no
	// adverts, which is the state the server ships in.
	Herald *HeraldTakings `json:"herald,omitempty"`
}

// HeraldTakings is the rewarded advert over the window: what was actually
// watched, and the diamonds it cost to say so.
//
// The pair to watch is started against paid. A tap is a ticket and a PAID watch
// is one Google came back for, so a fill far below 100% is the SDK failing to
// fill, a lord closing the advert early, or -- the one worth waking up for --
// this server not being reachable at the callback. There is no revenue side to
// this table: what the adverts EARNED is AdMob's own report, and inventing a
// figure for it here would be inventing money.
type HeraldTakings struct {
	// The window these figures actually cover, which is the takings' window cut
	// to what the table still holds: a paid watch is swept after
	// service.AdWatchKeep, so a 365-day read of the takings cannot be a 365-day
	// read of the herald, and saying it was would be saying adverts stopped.
	Days     int   `json:"days"`
	Started  int64 `json:"started"`
	Paid     int64 `json:"paid"`
	Lords    int64 `json:"lords"`
	Diamonds int64 `json:"diamonds"`
	// Watches paid over watches started, in basis points.
	FillBP int64 `json:"fill_bp"`
}

// BillingDay is one UTC day.
type BillingDay struct {
	Day         string `json:"day"`
	GrossCents  int64  `json:"gross_cents"`
	RefundCents int64  `json:"refund_cents"`
	Purchases   int64  `json:"purchases"`
}

// ProductTakings is one product over the window.
type ProductTakings struct {
	ProductID  string `json:"product_id"`
	Name       string `json:"name"`
	Purchases  int64  `json:"purchases"`
	GrossCents int64  `json:"gross_cents"`
	Refunds    int64  `json:"refunds"`
	Buyers     int64  `json:"buyers"`
}

// RefundFlag is a lord who refunds often.
type RefundFlag struct {
	PlayerID    string    `json:"player_id"`
	Username    string    `json:"username"`
	Deleted     bool      `json:"deleted"`
	Refunds     int64     `json:"refunds"`
	RefundCents int64     `json:"refund_cents"`
	LastRefund  time.Time `json:"last_refund"`
}

// abandonAfter is how long the notification job keeps retrying (see
// ClaimDueNotifications). Past it, only the desk's RETRY acts on one.
const abandonAfter = 72 * time.Hour

// BillingSummary reads the takings over the last `days` days.
func (s *Service) BillingSummary(ctx context.Context, days int) (*BillingSummary, error) {
	if days <= 0 || days > 365 {
		days = 30
	}
	cfg := s.Config.Get()
	q := sqlcdb.New(s.Pool)
	now := s.now()
	since := now.AddDate(0, 0, -(days - 1)).Truncate(24 * time.Hour)

	tot, err := q.BillingTotals(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("totals: %w", err)
	}
	ref, err := q.BillingRefunds(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("refunds: %w", err)
	}
	out := &BillingSummary{
		Days: days, GrossCents: tot.GrossCents, RefundCents: ref.RefundCents,
		NetCents: tot.GrossCents - ref.RefundCents, Purchases: tot.Purchases, Refunds: ref.Refunds,
		Revoked: ref.Revoked, Payers: tot.Payers, SandboxPurchases: tot.SandboxPurchases,
		SandboxCents: tot.SandboxCents, Daily: []BillingDay{}, Products: []ProductTakings{},
		Flagged: []RefundFlag{}, FlagRefunds: cfg.Commerce.RefundFlagCount, FlagDays: cfg.Commerce.RefundFlagDays,
	}
	if tot.Payers > 0 {
		out.ARPPUCents = out.NetCents / tot.Payers
	}
	act, err := q.ActiveInWindow(ctx, pgtype.Date{Time: since, Valid: true})
	if err != nil {
		return nil, fmt.Errorf("active: %w", err)
	}
	out.ActiveLords = act.Lords
	if act.LordDays > 0 {
		out.ARPDAUCentiCents = out.NetCents * 100 / act.LordDays
	}
	if act.Lords > 0 {
		out.ConversionBP = tot.Payers * 10000 / act.Lords
	}

	daily, err := q.BillingDaily(ctx, sqlcdb.BillingDailyParams{Since: since, Until: now})
	if err != nil {
		return nil, fmt.Errorf("daily: %w", err)
	}
	for _, d := range daily {
		out.Daily = append(out.Daily, BillingDay{Day: d.Day.Time.Format("2006-01-02"),
			GrossCents: d.GrossCents, RefundCents: d.RefundCents, Purchases: d.Purchases})
	}

	prods, err := q.BillingByProduct(ctx, since)
	if err != nil {
		return nil, fmt.Errorf("by product: %w", err)
	}
	for _, p := range prods {
		name := p.ProductID
		if pr := cfg.Product(p.ProductID); pr != nil {
			name = pr.Title
		}
		out.Products = append(out.Products, ProductTakings{ProductID: p.ProductID, Name: name,
			Purchases: p.Purchases, GrossCents: p.GrossCents, Refunds: p.Refunds, Buyers: p.Buyers})
	}

	flags, err := q.RefundFlagged(ctx, sqlcdb.RefundFlaggedParams{
		Since: now.AddDate(0, 0, -cfg.Commerce.RefundFlagDays), MinRefunds: int64(cfg.Commerce.RefundFlagCount),
	})
	if err != nil {
		return nil, fmt.Errorf("flags: %w", err)
	}
	for _, f := range flags {
		out.Flagged = append(out.Flagged, RefundFlag{PlayerID: f.PlayerID.String(), Username: f.Username,
			Deleted: f.Deleted, Refunds: f.Refunds, RefundCents: f.RefundCents, LastRefund: f.LastRefund})
	}

	// The herald, on a realm that has one. A realm with no adverts has an empty
	// table and no section on the desk rather than a row of zeros.
	adDays, adSince := days, since
	if oldest := now.Add(-service.AdWatchKeep); adSince.Before(oldest) {
		adSince, adDays = oldest, int(service.AdWatchKeep/(24*time.Hour))
	}
	if ads, err := q.DeskAds(ctx, adSince); err != nil {
		return nil, fmt.Errorf("the herald: %w", err)
	} else if ads.Started > 0 {
		h := &HeraldTakings{Days: adDays, Started: ads.Started, Paid: ads.Paid,
			Lords: ads.Lords, Diamonds: ads.Diamonds}
		h.FillBP = ads.Paid * 10000 / ads.Started
		out.Herald = h
	}

	open, err := q.AdminListIAPNotifications(ctx, sqlcdb.AdminListIAPNotificationsParams{OpenOnly: true, Lim: 500})
	if err != nil {
		return nil, fmt.Errorf("open notifications: %w", err)
	}
	for _, n := range open {
		if now.Sub(n.ReceivedAt) > abandonAfter {
			out.AbandonedNotices++
		} else {
			out.PendingNotices++
		}
	}
	return out, nil
}

// TxnFilter narrows the transaction list. Zero values do not filter.
type TxnFilter struct {
	PlayerID    *uuid.UUID
	Environment string // "Production" or "Sandbox"
	State       string // "granted", "refunded" or "revoked"
	Search      string // a transaction id or an original transaction id
	BeforeID    int64
	Limit       int32
}

// TxnRow is one purchase as the desk shows it.
type TxnRow struct {
	ID                    int64      `json:"id"`
	TransactionID         string     `json:"transaction_id"`
	OriginalTransactionID string     `json:"original_transaction_id"`
	PlayerID              string     `json:"player_id"`
	Username              string     `json:"username"`
	Deleted               bool       `json:"deleted"`
	ProductID             string     `json:"product_id"`
	ProductName           string     `json:"product_name"`
	StoreProductID        string     `json:"store_product_id"`
	Kind                  string     `json:"kind"`
	Environment           string     `json:"environment"`
	Sandbox               bool       `json:"sandbox"`
	PurchasedAt           time.Time  `json:"purchased_at"`
	ExpiresAt             *time.Time `json:"expires_at"`
	USDCents              int64      `json:"usd_cents"`
	// What the buyer paid in their own currency: 4.99 is 4990 milliunits.
	PriceMilli *int64          `json:"price_milli"`
	Currency   string          `json:"currency"`
	Storefront string          `json:"storefront"`
	Granted    json.RawMessage `json:"granted"`
	State      string          `json:"state"`
	RefundedAt *time.Time      `json:"refunded_at"`
	RefundNote string          `json:"refund_note"`
}

// Transactions lists purchases newest first.
func (s *Service) Transactions(ctx context.Context, f TxnFilter) ([]TxnRow, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	switch f.Environment {
	case "", "Production", "Sandbox":
	default:
		return nil, fmt.Errorf("%w: environment is Production or Sandbox", ErrOutOfRange)
	}
	switch f.State {
	case "", "granted", "refunded", "revoked":
	default:
		return nil, fmt.Errorf("%w: state is granted, refunded or revoked", ErrOutOfRange)
	}
	rows, err := sqlcdb.New(s.Pool).AdminListIAP(ctx, sqlcdb.AdminListIAPParams{
		PlayerID: f.PlayerID, Environment: f.Environment, State: f.State,
		Search: strings.TrimSpace(f.Search), BeforeID: f.BeforeID, Lim: f.Limit,
	})
	if err != nil {
		return nil, fmt.Errorf("transactions: %w", err)
	}
	cfg := s.Config.Get()
	out := make([]TxnRow, 0, len(rows))
	for _, r := range rows {
		t := TxnRow{
			ID: r.ID, TransactionID: r.TransactionID, OriginalTransactionID: r.OriginalTransactionID,
			PlayerID: r.PlayerID.String(), Username: r.Username, Deleted: r.Deleted, ProductID: r.ProductID,
			ProductName: r.ProductID, StoreProductID: r.StoreProductID, Kind: r.Kind,
			Environment: r.Environment, Sandbox: r.Environment != "Production", PurchasedAt: r.PurchasedAt,
			ExpiresAt: r.ExpiresAt, USDCents: r.UsdCents, Granted: json.RawMessage(r.Granted),
			State: r.State, RefundedAt: r.RefundedAt,
		}
		if pr := cfg.Product(r.ProductID); pr != nil {
			t.ProductName = pr.Title
		}
		if r.PriceMilli.Valid {
			v := r.PriceMilli.Int64
			t.PriceMilli = &v
		}
		if r.Currency != nil {
			t.Currency = *r.Currency
		}
		if r.Storefront != nil {
			t.Storefront = *r.Storefront
		}
		if r.RefundNote != nil {
			t.RefundNote = *r.RefundNote
		}
		if len(t.Granted) == 0 {
			t.Granted = json.RawMessage("{}")
		}
		out = append(out, t)
	}
	return out, nil
}

// NotificationRow is one App Store notification as the desk shows it.
type NotificationRow struct {
	ID                    int64      `json:"id"`
	UUID                  string     `json:"uuid"`
	Type                  string     `json:"type"`
	Subtype               string     `json:"subtype"`
	Environment           string     `json:"environment"`
	TransactionID         string     `json:"transaction_id"`
	OriginalTransactionID string     `json:"original_transaction_id"`
	ReceivedAt            time.Time  `json:"received_at"`
	ProcessedAt           *time.Time `json:"processed_at"`
	Outcome               string     `json:"outcome"`
	Attempts              int32      `json:"attempts"`
	LastError             string     `json:"last_error"`
	NextAttemptAt         *time.Time `json:"next_attempt_at"`
	// done, pending (the job will try again) or abandoned (its 72 hours are up).
	Status string `json:"status"`
}

// Notifications lists App Store notifications newest first.
func (s *Service) Notifications(ctx context.Context, openOnly bool, limit int32) ([]NotificationRow, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := sqlcdb.New(s.Pool).AdminListIAPNotifications(ctx, sqlcdb.AdminListIAPNotificationsParams{
		OpenOnly: openOnly, Lim: limit,
	})
	if err != nil {
		return nil, fmt.Errorf("notifications: %w", err)
	}
	now := s.now()
	out := make([]NotificationRow, 0, len(rows))
	for _, r := range rows {
		n := NotificationRow{ID: r.ID, UUID: r.NotificationUuid, Type: r.Type, Subtype: r.Subtype,
			Environment: r.Environment, ReceivedAt: r.ReceivedAt, ProcessedAt: r.ProcessedAt,
			Attempts: r.Attempts, Status: "done"}
		if r.TransactionID != nil {
			n.TransactionID = *r.TransactionID
		}
		if r.OriginalTransactionID != nil {
			n.OriginalTransactionID = *r.OriginalTransactionID
		}
		if r.Outcome != nil {
			n.Outcome = *r.Outcome
		}
		if r.LastError != nil {
			n.LastError = *r.LastError
		}
		if r.ProcessedAt == nil {
			n.Status = "pending"
			if now.Sub(r.ReceivedAt) > abandonAfter {
				n.Status = "abandoned"
			} else {
				at := r.NextAttemptAt
				n.NextAttemptAt = &at
			}
		}
		out = append(out, n)
	}
	return out, nil
}

// RetryNotification acts on one stored notification now.
func (s *Service) RetryNotification(ctx context.Context, who *Identity, id int64) (string, error) {
	if !AtLeast(who.Role, "moderator") {
		return "", ErrForbidden
	}
	if s.Billing == nil {
		return "", ErrUnavailable
	}
	out, err := s.Billing.RetryNotification(ctx, id)
	if err != nil {
		return "", err
	}
	if !noOp(out) {
		s.Audit(ctx, who, "billing.retry", fmt.Sprint(id), nil, map[string]any{"outcome": out}, "")
	}
	return out, nil
}

// noOp reports an outcome that changed nothing ("already processed", "already
// refunded"): the audit is of what was done, and a second press did nothing.
func noOp(outcome string) bool { return strings.HasPrefix(outcome, "already ") }

// TakeBack undoes a delivered purchase: "refunded" for a refund Apple made
// whose notice never arrived, "revoked" for one support takes back. It moves
// a lord's paid-for diamonds, so it is a designer's call, with a reason.
func (s *Service) TakeBack(ctx context.Context, who *Identity, transactionID, state, note string) (string, error) {
	if !AtLeast(who.Role, "designer") {
		return "", ErrForbidden
	}
	if s.Billing == nil {
		return "", ErrUnavailable
	}
	note = strings.TrimSpace(note)
	if note == "" {
		return "", fmt.Errorf("%w: say why the purchase is taken back", ErrOutOfRange)
	}
	if state != "refunded" && state != "revoked" {
		return "", fmt.Errorf("%w: a purchase is taken back as refunded or revoked", ErrOutOfRange)
	}
	out, err := s.Billing.TakeBack(ctx, strings.TrimSpace(transactionID), state,
		fmt.Sprintf("%s by %s: %s", state, who.Username, note))
	if err != nil {
		return "", err
	}
	if !noOp(out) {
		s.Audit(ctx, who, "billing.take_back", transactionID, nil, map[string]any{"state": state, "outcome": out}, note)
	}
	return out, nil
}

// ForgiveDebt clears a lord's refund debt. The ledger records it as the admin
// credit it is -- the whole debt, none of it reaching the purse -- so the
// balance still reconciles and the economy view sees what was forgiven.
func (s *Service) ForgiveDebt(ctx context.Context, who *Identity, playerID uuid.UUID, note string) (*PlayerRow, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	note = strings.TrimSpace(note)
	if note == "" {
		return nil, fmt.Errorf("%w: say why the debt is forgiven", ErrOutOfRange)
	}
	before, after, err := s.lockedWrite(ctx, playerID, func(q *sqlcdb.Queries, p sqlcdb.AppPlayer) (sqlcdb.AppPlayer, error) {
		if p.DiamondDebt == 0 {
			return p, ErrNothingToDo
		}
		// A credit of exactly the debt: it all goes to the debt, none to the purse.
		after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: p.DiamondDebt})
		if err != nil {
			return p, fmt.Errorf("forgive: %w", err)
		}
		if err := ledger.Diamonds(ctx, q, p, after, p.DiamondDebt, ledger.DebtForgiven, who.Username); err != nil {
			return p, err
		}
		return after, nil
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, "player.forgive_debt", playerID.String(),
		map[string]any{"diamonds": before.Diamonds, "diamond_debt": before.DiamondDebt},
		map[string]any{"diamonds": after.Diamonds, "diamond_debt": after.DiamondDebt}, note)
	return playerRow(after), nil
}

// PlayerBilling is everything money left on one lord.
type PlayerBilling struct {
	VIPPoints int64 `json:"vip_points"` // US cents spent, less refunds
	VIPLevel  int   `json:"vip_level"`
	// Points the next level needs; 0 at the top.
	VIPNextAt        int64          `json:"vip_next_at"`
	PatronUntil      *time.Time     `json:"patron_until"`
	Steward          bool           `json:"steward"`
	BagBonus         int32          `json:"bag_bonus"`
	StipendUntil     string         `json:"stipend_until"`
	StipendClaimed   string         `json:"stipend_claimed"`
	Diamonds         int64          `json:"diamonds"`
	DiamondDebt      int64          `json:"diamond_debt"`
	SpentCents       int64          `json:"spent_cents"`
	Purchases        int64          `json:"purchases"`
	SandboxPurchases int64          `json:"sandbox_purchases"`
	RecentRefunds    int64          `json:"recent_refunds"`
	Flagged          bool           `json:"flagged"`
	Entitlements     []Entitlement  `json:"entitlements"`
	Subscriptions    []Subscription `json:"subscriptions"`
	Bought           []Bought       `json:"bought"`
	Offers           []OfferRow     `json:"offers"`
	Transactions     []TxnRow       `json:"transactions"`
}

// Entitlement is a lasting right a purchase gave.
type Entitlement struct {
	Name          string    `json:"name"`
	TransactionID string    `json:"transaction_id"`
	GrantedAt     time.Time `json:"granted_at"`
}

// Subscription is one Crown Patronage chain.
type Subscription struct {
	OriginalTransactionID string    `json:"original_transaction_id"`
	ProductID             string    `json:"product_id"`
	Environment           string    `json:"environment"`
	Status                string    `json:"status"`
	ExpiresAt             time.Time `json:"expires_at"`
	AutoRenew             bool      `json:"auto_renew"`
	UpdatedAt             time.Time `json:"updated_at"`
}

// Bought is how many of one product a lord has bought.
type Bought struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Count     int32  `json:"count"`
}

// OfferRow is an offer shown to a lord.
type OfferRow struct {
	ProductID string     `json:"product_id"`
	Name      string     `json:"name"`
	FiredAt   time.Time  `json:"fired_at"`
	ExpiresAt time.Time  `json:"expires_at"`
	SeenAt    *time.Time `json:"seen_at"`
}

// PlayerBilling reads one lord's purchases and what they left.
func (s *Service) PlayerBilling(ctx context.Context, playerID uuid.UUID) (*PlayerBilling, error) {
	q := sqlcdb.New(s.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	cfg := s.Config.Get()
	now := s.now()
	name := func(id string) string {
		if pr := cfg.Product(id); pr != nil {
			return pr.Title
		}
		return id
	}
	out := &PlayerBilling{
		VIPPoints: p.VipPoints, VIPLevel: cfg.VIPLevel(p.VipPoints), Steward: p.StewardOwned,
		BagBonus: p.BagBonus, Diamonds: p.Diamonds, DiamondDebt: p.DiamondDebt,
		Entitlements: []Entitlement{}, Subscriptions: []Subscription{}, Bought: []Bought{},
		Offers: []OfferRow{},
	}
	for _, t := range cfg.Commerce.VIP {
		if t.Points > p.VipPoints {
			out.VIPNextAt = t.Points
			break
		}
	}
	if p.PatronUntil != nil && p.PatronUntil.After(now) {
		out.PatronUntil = p.PatronUntil
	}
	if p.StipendUntil.Valid {
		out.StipendUntil = p.StipendUntil.Time.Format("2006-01-02")
	}
	if p.StipendClaimed.Valid {
		out.StipendClaimed = p.StipendClaimed.Time.Format("2006-01-02")
	}

	spend, err := q.PlayerSpend(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("spend: %w", err)
	}
	out.SpentCents, out.Purchases, out.SandboxPurchases = spend.SpentCents, spend.Purchases, spend.SandboxPurchases

	n, err := q.CountRecentRefunds(ctx, sqlcdb.CountRecentRefundsParams{
		PlayerID: p.ID, Since: now.AddDate(0, 0, -cfg.Commerce.RefundFlagDays),
	})
	if err != nil {
		return nil, fmt.Errorf("refunds: %w", err)
	}
	out.RecentRefunds = int64(n)
	out.Flagged = int(n) >= cfg.Commerce.RefundFlagCount

	ents, err := q.ListEntitlements(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("entitlements: %w", err)
	}
	for _, e := range ents {
		out.Entitlements = append(out.Entitlements, Entitlement{Name: e.Entitlement,
			TransactionID: e.TransactionID, GrantedAt: e.GrantedAt})
	}
	subs, err := q.ListPlayerSubscriptions(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("subscriptions: %w", err)
	}
	for _, sub := range subs {
		out.Subscriptions = append(out.Subscriptions, Subscription{
			OriginalTransactionID: sub.OriginalTransactionID, ProductID: sub.ProductID,
			Environment: sub.Environment, Status: sub.Status, ExpiresAt: sub.ExpiresAt,
			AutoRenew: sub.AutoRenew, UpdatedAt: sub.UpdatedAt,
		})
	}
	counts, err := q.ListPurchaseCounts(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("purchase counts: %w", err)
	}
	for _, c := range counts {
		out.Bought = append(out.Bought, Bought{ProductID: c.ProductID, Name: name(c.ProductID), Count: c.Bought})
	}
	offers, err := q.ListOffers(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("offers: %w", err)
	}
	for _, o := range offers {
		out.Offers = append(out.Offers, OfferRow{ProductID: o.ProductID, Name: name(o.ProductID),
			FiredAt: o.FiredAt, ExpiresAt: o.ExpiresAt, SeenAt: o.SeenAt})
	}
	if out.Transactions, err = s.Transactions(ctx, TxnFilter{PlayerID: &p.ID, Limit: 50}); err != nil {
		return nil, err
	}
	return out, nil
}

// A lasting right given by hand: support's answer when a lord has lost what
// they paid for in a way no purchase record can mend. Recorded under the
// transaction "admin:<who>" so the panel can tell it from a bought one: a
// later purchase of the same right leaves it as it is, TakeBack never finds
// it, and RevokeEntitlement takes back only a right given this way.

// GrantEntitlement gives a lord the Steward or the Quartermaster's room.
func (s *Service) GrantEntitlement(ctx context.Context, who *Identity, playerID uuid.UUID, name, note string) (*PlayerBilling, error) {
	return s.changeEntitlement(ctx, who, playerID, name, note, true)
}

// RevokeEntitlement takes back a right the panel gave.
func (s *Service) RevokeEntitlement(ctx context.Context, who *Identity, playerID uuid.UUID, name, note string) (*PlayerBilling, error) {
	return s.changeEntitlement(ctx, who, playerID, name, note, false)
}

func (s *Service) changeEntitlement(ctx context.Context, who *Identity, playerID uuid.UUID, name, note string, grant bool) (*PlayerBilling, error) {
	if !AtLeast(who.Role, "designer") {
		return nil, ErrForbidden
	}
	note = strings.TrimSpace(note)
	if note == "" {
		return nil, fmt.Errorf("%w: say why", ErrOutOfRange)
	}
	cfg := s.Config.Get()
	bonus, known := 0, false
	for _, pr := range cfg.Commerce.Products {
		if pr.Entitlement == name {
			known = true
		}
		if pr.Entitlement == gameconfig.EntitlementQuartermaster {
			bonus = pr.BagBonus
		}
	}
	if !known {
		return nil, fmt.Errorf("%w: no lasting right is called %q", ErrOutOfRange, name)
	}
	action := "player.entitlement_revoke"
	if grant {
		action = "player.entitlement_grant"
	}
	before, after, err := s.lockedWrite(ctx, playerID, func(q *sqlcdb.Queries, p sqlcdb.AppPlayer) (sqlcdb.AppPlayer, error) {
		if grant {
			if _, err := q.GrantEntitlement(ctx, sqlcdb.GrantEntitlementParams{
				PlayerID: p.ID, Entitlement: name, TransactionID: "admin:" + who.Username,
			}); errors.Is(err, pgx.ErrNoRows) {
				return p, fmt.Errorf("%w: they hold it already", ErrNothingToDo)
			} else if err != nil {
				return p, fmt.Errorf("grant: %w", err)
			}
		} else {
			at := s.now()
			n, err := q.RevokeAdminEntitlement(ctx, sqlcdb.RevokeAdminEntitlementParams{
				PlayerID: p.ID, Entitlement: name, At: &at,
			})
			if err != nil {
				return p, fmt.Errorf("revoke: %w", err)
			}
			if n == 0 {
				return p, fmt.Errorf("%w: they hold no %s the panel gave", ErrNothingToDo, name)
			}
		}
		return q.SyncEntitlementFlags(ctx, sqlcdb.SyncEntitlementFlagsParams{ID: p.ID, QuartermasterBonus: int32(bonus)})
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, who, action, playerID.String(),
		map[string]any{"entitlement": name, "steward": before.StewardOwned, "bag_bonus": before.BagBonus},
		map[string]any{"entitlement": name, "steward": after.StewardOwned, "bag_bonus": after.BagBonus}, note)
	return s.PlayerBilling(ctx, playerID)
}
