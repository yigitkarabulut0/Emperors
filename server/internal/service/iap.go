package service

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

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// Purchases.
//
// The phone buys through StoreKit and sends the App Store's signed transaction
// here; nothing is granted until iap.Verifier has proved it Apple's, for this
// app, for this lord. Then it is delivered exactly once -- the unique
// transaction row is the whole of that guarantee -- and only after the server
// answers does the phone finish the transaction, so a purchase that never
// reached us is sent again on the next launch rather than lost.
//
// No action_seq anywhere here: money arrives on Apple's schedule, and it must
// never move the sequence the client's queued collects are counting on
// (CLAUDE.md: one way in for each kind of change).
var (
	ErrIAPUnavailable    = errors.New("purchases are not available on this server")
	ErrIAPInvalid        = errors.New("that purchase could not be verified")
	ErrIAPWrongApp       = errors.New("that purchase was made for another app")
	ErrIAPOwnedByAnother = errors.New("that purchase belongs to another lord's account")
	ErrIAPUnknownProduct = errors.New("that product is not sold in this version of the realm")
)

// Delivery is what a purchase brought, for the ceremony that shows it.
type Delivery struct {
	TransactionID string `json:"transaction_id"`
	Product       string `json:"product"`
	Title         string `json:"title"`
	// Delivered before: nothing new was granted. The phone finishes it anyway.
	Already bool `json:"already"`
	// Refunded or revoked before it reached us: nothing was granted.
	Revoked bool `json:"revoked"`
	// Delivered to the lord who bought it, who is not the one whose session
	// sent it (two lords on one phone). The phone finishes it and says where
	// it went; this lord's snapshot is unchanged.
	ForAnother bool `json:"for_another,omitempty"`
	// The first purchase of this pack paid double.
	FirstBonus bool           `json:"first_bonus"`
	Lines      []rewards.Line `json:"lines"`
	VIPLevel   int            `json:"vip_level"`
	// A Royal Favour level this purchase reached; 0 when none.
	VIPReached int       `json:"vip_reached,omitempty"`
	Snapshot   *Snapshot `json:"snapshot,omitempty"`
}

// VerifyApple verifies a signed transaction and delivers it -- to the lord who
// bought it.
//
// The phone sets appAccountToken to the buying lord's id and Apple signs it, so
// the token is proof of whose purchase it is. A purchase another lord's session
// sends -- two lords on one phone, the app closed before the first answer came
// -- is delivered to its buyer all the same, and ForAnother tells this phone to
// finish it and say where it went. Refusing it instead would leave the phone a
// choice between finishing a purchase nobody received and re-sending it forever.
func (d Deps) VerifyApple(ctx context.Context, playerID uuid.UUID, signed string) (*Delivery, error) {
	t, err := d.verifyAppleTransaction(signed)
	if err != nil {
		return nil, err
	}
	recipient := playerID
	if tok, err := uuid.Parse(t.AppAccountToken); err == nil && tok != playerID {
		recipient = tok
	}
	var out Delivery
	if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, recipient)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				if recipient != playerID {
					// The lord who bought it has deleted their account: there is
					// nobody to deliver it to, now or later.
					return fmt.Errorf("%w: the account that bought this no longer exists", ErrIAPOwnedByAnother)
				}
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		out, err = d.deliverApple(ctx, tx, q, &p, t, signed)
		return err
	}); err != nil {
		return nil, err
	}
	out.ForAnother = recipient != playerID
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	out.Snapshot = snap
	return &out, nil
}

// RestoreResult is what a restore found.
type RestoreResult struct {
	Restored []Delivery `json:"restored"`
	// Transactions that could not be restored to this lord, and why.
	Refused  []RestoreRefusal `json:"refused"`
	Snapshot *Snapshot        `json:"snapshot"`
}

// RestoreRefusal names one transaction a restore could not bring back.
type RestoreRefusal struct {
	TransactionID string `json:"transaction_id,omitempty"`
	Reason        string `json:"reason"`
}

// RestoreApple brings back what this Apple ID owns: the Steward, the
// Quartermaster, a running patronage. Each signed transaction is delivered as
// a purchase would be -- already-delivered ones are no-ops -- so a restore on a
// new phone, or after a reinstall, puts every lasting right back where it was.
func (d Deps) RestoreApple(ctx context.Context, playerID uuid.UUID, signed []string) (*RestoreResult, error) {
	if d.IAP == nil {
		return nil, ErrIAPUnavailable
	}
	if len(signed) > 50 {
		signed = signed[:50]
	}
	res := &RestoreResult{Restored: []Delivery{}, Refused: []RestoreRefusal{}}
	for _, s := range signed {
		t, err := d.verifyAppleTransaction(s)
		if err != nil {
			res.Refused = append(res.Refused, RestoreRefusal{Reason: err.Error()})
			continue
		}
		// Consumables are never restored: they were spent when they arrived.
		if pr := d.Config.ProductByStoreID(t.ProductID); pr != nil && pr.Kind == gameconfig.ProductConsumable {
			continue
		}
		var del Delivery
		err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			q := sqlcdb.New(tx)
			p, err := q.LockPlayer(ctx, playerID)
			if err != nil {
				return fmt.Errorf("lock player: %w", err)
			}
			del, err = d.deliverApple(ctx, tx, q, &p, t, s)
			return err
		})
		if err != nil {
			res.Refused = append(res.Refused, RestoreRefusal{TransactionID: t.TransactionID, Reason: err.Error()})
			continue
		}
		res.Restored = append(res.Restored, del)
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	res.Snapshot = snap
	return res, nil
}

func (d Deps) verifyAppleTransaction(signed string) (*iap.Transaction, error) {
	if d.IAP == nil {
		return nil, ErrIAPUnavailable
	}
	t, err := d.IAP.Transaction(signed)
	switch {
	case err == nil:
		return t, nil
	case errors.Is(err, iap.ErrWrongApp):
		return nil, fmt.Errorf("%w: %v", ErrIAPWrongApp, err)
	default:
		return nil, fmt.Errorf("%w: %v", ErrIAPInvalid, err)
	}
}

// deliverApple grants a verified transaction to the locked lord, once.
func (d Deps) deliverApple(ctx context.Context, tx pgx.Tx, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	t *iap.Transaction, signed string) (Delivery, error) {

	// Whose purchase it is. The phone sets appAccountToken to the lord's id when
	// it buys; a purchase chain already delivered belongs to whoever received it.
	if t.AppAccountToken != "" {
		tok, err := uuid.Parse(t.AppAccountToken)
		if err != nil || tok != p.ID {
			return Delivery{}, ErrIAPOwnedByAnother
		}
	}
	if owner, err := q.OwnerOfOriginal(ctx, t.OriginalTransactionID); err == nil && owner != p.ID {
		return Delivery{}, ErrIAPOwnedByAnother
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Delivery{}, fmt.Errorf("owner: %w", err)
	}

	pr := d.Config.ProductByStoreID(t.ProductID)
	if pr == nil {
		// Not finished by the phone, so Apple keeps it: a catalog published
		// with the product delivers it on the next try.
		return Delivery{}, fmt.Errorf("%w: %s", ErrIAPUnknownProduct, t.ProductID)
	}
	del := Delivery{TransactionID: t.TransactionID, Product: pr.ID, Title: pr.Title, Lines: []rewards.Line{},
		VIPLevel: d.vipLevel(*p)}

	var expires *time.Time
	if e := t.ExpiresDate(); !e.IsZero() {
		expires = &e
	}
	price := pgtype.Int8{Int64: t.Price, Valid: t.Price != 0}
	row, err := q.InsertIAPTransaction(ctx, sqlcdb.InsertIAPTransactionParams{
		TransactionID: t.TransactionID, OriginalTransactionID: t.OriginalTransactionID, PlayerID: p.ID,
		ProductID: pr.ID, StoreProductID: t.ProductID, Kind: pr.Kind, Environment: t.Environment,
		PurchasedAt: t.PurchaseDate(), ExpiresAt: expires, UsdCents: pr.USDCents, PriceMilli: price,
		Currency: nilIfEmpty(t.Currency), Storefront: nilIfEmpty(t.Storefront), Signed: signed,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// Delivered before, to this lord (the owner check above). Say what it gave.
		prev, gerr := q.GetIAPTransaction(ctx, t.TransactionID)
		if gerr != nil {
			return Delivery{}, fmt.Errorf("delivered transaction: %w", gerr)
		}
		del.Already = true
		del.Revoked = prev.State != "granted"
		_ = json.Unmarshal(prev.Granted, &del.Lines)
		if del.Lines == nil {
			del.Lines = []rewards.Line{}
		}
		return del, nil
	}
	if err != nil {
		return Delivery{}, fmt.Errorf("record transaction: %w", err)
	}

	// Refunded or revoked before it ever reached us: recorded, and nothing given.
	if t.Revoked() {
		at := t.RevocationDate()
		if _, err := q.MarkIAPUndone(ctx, sqlcdb.MarkIAPUndoneParams{
			TransactionID: t.TransactionID, State: "revoked", At: &at,
			Note: nilIfEmpty("revoked before delivery"),
		}); err != nil {
			return Delivery{}, fmt.Errorf("mark revoked: %w", err)
		}
		del.Revoked = true
		return del, nil
	}

	bought, err := q.BumpPurchase(ctx, sqlcdb.BumpPurchaseParams{PlayerID: p.ID, ProductID: pr.ID})
	if err != nil {
		return Delivery{}, fmt.Errorf("count purchase: %w", err)
	}
	src := GrantSource{Diamonds: ledger.Purchase, Gold: "purchase", Ref: t.TransactionID, ItemFrom: "purchase",
		Paid: true, DupeDiamonds: pr.FallbackDiamonds}

	switch pr.Kind {
	case gameconfig.ProductConsumable:
		b := pr.Grant
		if pr.FirstBonusBP > 0 && bought == 1 {
			b.Diamonds += b.Diamonds * pr.FirstBonusBP / 10000
			del.FirstBonus = true
		}
		if !b.Empty() {
			g, err := d.grantBundle(ctx, q, p, b, src)
			if err != nil {
				return Delivery{}, err
			}
			del.Lines = append(del.Lines, g.Lines...)
			if g.DuplicateDiamonds > 0 {
				del.Lines = append(del.Lines, rewards.Line{Kind: "diamonds", Amount: g.DuplicateDiamonds,
					Text: rewards.Group(g.DuplicateDiamonds) + " diamonds for what you already owned", Icon: "diamond"})
			}
		}
		if pr.Stipend != nil {
			line, err := d.startStipend(ctx, q, p, pr.Stipend, t.TransactionID)
			if err != nil {
				return Delivery{}, err
			}
			del.Lines = append(del.Lines, line)
		}
		if pr.SeasonPass {
			lines, err := d.deliverCharter(ctx, q, p, pr, t.TransactionID)
			if err != nil {
				return Delivery{}, err
			}
			del.Lines = append(del.Lines, lines...)
		}
		if pr.Largesse != nil {
			line, err := d.sendLargesse(ctx, q, *p, pr, t.TransactionID)
			if err != nil {
				return Delivery{}, err
			}
			if line.Text != "" {
				del.Lines = append(del.Lines, line)
			}
		}

	case gameconfig.ProductNonConsumable:
		if _, err := q.GrantEntitlement(ctx, sqlcdb.GrantEntitlementParams{
			PlayerID: p.ID, Entitlement: pr.Entitlement, TransactionID: t.TransactionID,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return Delivery{}, fmt.Errorf("entitlement: %w", err)
		}
		after, err := q.SyncEntitlementFlags(ctx, sqlcdb.SyncEntitlementFlagsParams{
			ID: p.ID, QuartermasterBonus: int32(d.quartermasterBonus()),
		})
		if err != nil {
			return Delivery{}, fmt.Errorf("entitlement flags: %w", err)
		}
		*p = after
		del.Lines = append(del.Lines, entitlementLine(pr))

	case gameconfig.ProductSubscription:
		lines, err := d.applyPatronage(ctx, q, p, pr, t, "active")
		if err != nil {
			return Delivery{}, err
		}
		del.Lines = append(del.Lines, lines...)
	}

	reached, err := d.addRoyalFavour(ctx, q, p, pr.USDCents)
	if err != nil {
		return Delivery{}, err
	}
	del.VIPReached, del.VIPLevel = reached, d.vipLevel(*p)

	raw, _ := json.Marshal(del.Lines)
	if err := q.SetIAPGranted(ctx, sqlcdb.SetIAPGrantedParams{ID: row.ID, Granted: raw}); err != nil {
		return Delivery{}, fmt.Errorf("record grant: %w", err)
	}
	if d.Log != nil {
		d.Log.Info("purchase delivered", "player", p.ID, "product", pr.ID, "transaction", t.TransactionID,
			"environment", t.Environment, "usd_cents", pr.USDCents)
	}
	return del, nil
}

func entitlementLine(pr *gameconfig.Product) rewards.Line {
	switch pr.Entitlement {
	case gameconfig.EntitlementSteward:
		return rewards.Line{Kind: "entitlement", ID: pr.Entitlement, Amount: 1,
			Text: "The Steward now keeps your house", Icon: "steward"}
	default:
		return rewards.Line{Kind: "entitlement", ID: pr.Entitlement, Amount: int64(pr.BagBonus),
			Text: fmt.Sprintf("+%d bag slots, for good", pr.BagBonus), Icon: "quartermaster"}
	}
}

// quartermasterBonus is the bag slots the Quartermaster adds.
func (d Deps) quartermasterBonus() int {
	for _, pr := range d.Config.Commerce.Products {
		if pr.Entitlement == gameconfig.EntitlementQuartermaster {
			return pr.BagBonus
		}
	}
	return 0
}

// addRoyalFavour adds a purchase's cents to Royal Favour and grants the
// cosmetics of every level it crosses. It returns the level reached, or 0.
func (d Deps) addRoyalFavour(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, cents int64) (int, error) {
	before := d.vipLevel(*p)
	after, err := q.AddVIPPoints(ctx, sqlcdb.AddVIPPointsParams{ID: p.ID, Delta: cents})
	if err != nil {
		return 0, fmt.Errorf("royal favour: %w", err)
	}
	*p = after
	now := d.vipLevel(after)
	for lvl := before + 1; lvl <= now; lvl++ {
		t := d.Config.VIPTier(lvl)
		if t == nil {
			continue
		}
		for _, id := range t.Cosmetics {
			if _, err := q.InsertCosmetic(ctx, sqlcdb.InsertCosmeticParams{
				PlayerID: p.ID, CosmeticID: id, Source: "vip", SourceRef: nilIfEmpty(vipRef(lvl)),
			}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return 0, fmt.Errorf("royal favour cosmetic: %w", err)
			}
		}
	}
	if now > before {
		return now, nil
	}
	return 0, nil
}

func vipRef(level int) string { return fmt.Sprintf("vip:%d", level) }

// startStipend starts the Royal Stipend, or lengthens a running one.
//
// The purchase day's share is due at once: a stipend bought today runs today
// and the days after it, Days in all.
func (d Deps) startStipend(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	st *gameconfig.StipendConfig, ref string) (rewards.Line, error) {
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	until := today.AddDate(0, 0, st.Days-1)
	if p.StipendUntil.Valid && !p.StipendUntil.Time.Before(today) {
		until = p.StipendUntil.Time.AddDate(0, 0, st.Days)
	}
	after, err := q.SetStipend(ctx, sqlcdb.SetStipendParams{
		ID: p.ID, Until: pgtype.Date{Time: until, Valid: true}, Ref: &ref,
	})
	if err != nil {
		return rewards.Line{}, fmt.Errorf("stipend: %w", err)
	}
	*p = after
	return rewards.Line{Kind: "stipend", Amount: st.DailyDiamonds,
		Text: fmt.Sprintf("%d diamonds to claim each day for %d days", st.DailyDiamonds, st.Days),
		Icon: "diamond"}, nil
}

// applyPatronage records a patronage period and pays it.
func (d Deps) applyPatronage(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer,
	pr *gameconfig.Product, t *iap.Transaction, status string) ([]rewards.Line, error) {
	pa := pr.Patronage
	expires := t.ExpiresDate()
	if expires.IsZero() {
		return nil, fmt.Errorf("%w: a subscription without an expiry", ErrIAPInvalid)
	}
	if _, err := q.UpsertSubscription(ctx, sqlcdb.UpsertSubscriptionParams{
		OriginalTransactionID: t.OriginalTransactionID, PlayerID: p.ID, ProductID: pr.ID,
		Environment: t.Environment, Status: status, ExpiresAt: expires, AutoRenew: true,
		LastTransactionID: t.TransactionID,
	}); err != nil {
		return nil, fmt.Errorf("subscription: %w", err)
	}
	if err := d.syncPatronUntil(ctx, q, p); err != nil {
		return nil, err
	}
	var lines []rewards.Line
	if pa.PeriodDiamonds > 0 {
		g, err := d.grantBundle(ctx, q, p, gameconfig.RewardBundle{Diamonds: pa.PeriodDiamonds},
			GrantSource{Diamonds: ledger.Patronage, Ref: t.TransactionID, Paid: true})
		if err != nil {
			return nil, err
		}
		lines = append(lines, g.Lines...)
	}
	if p.PatronUntil != nil {
		for _, id := range pa.Cosmetics {
			if err := q.HoldCosmeticUntil(ctx, sqlcdb.HoldCosmeticUntilParams{
				PlayerID: p.ID, CosmeticID: id, Source: "patronage",
				SourceRef: nilIfEmpty(t.OriginalTransactionID), Until: p.PatronUntil,
			}); err != nil {
				return nil, fmt.Errorf("patron cosmetic: %w", err)
			}
		}
	}
	var perks []string
	if pa.FreeRefillsPerDay > 0 {
		perks = append(perks, fmt.Sprintf("%d free refill%s each day", pa.FreeRefillsPerDay, plural(pa.FreeRefillsPerDay)))
	}
	if pa.BagBonus > 0 {
		perks = append(perks, fmt.Sprintf("+%d bag slots", pa.BagBonus))
	}
	if pa.Steward {
		perks = append(perks, "the Steward")
	}
	if len(perks) > 0 {
		lines = append(lines, rewards.Line{Kind: "patronage", Amount: 1,
			Text: "Crown Patronage: " + strings.Join(perks, ", "), Icon: "patronage"})
	}
	if p.PatronUntil != nil {
		if l, ok := patronLooksLine(d.Config, pa.Cosmetics); ok {
			lines = append(lines, l)
		}
	}
	return lines, nil
}

// syncPatronUntil sets the player's patronage to the latest of their live
// subscriptions, or none.
func (d Deps) syncPatronUntil(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer) error {
	until, err := q.PatronUntil(ctx, p.ID)
	if err != nil {
		return fmt.Errorf("patron until: %w", err)
	}
	var at *time.Time
	if until.After(time.Unix(0, 0)) {
		at = &until
	}
	after, err := q.SetPatronUntil(ctx, sqlcdb.SetPatronUntilParams{ID: p.ID, Until: at})
	if err != nil {
		return fmt.Errorf("set patron: %w", err)
	}
	*p = after
	return nil
}

// sendLargesse mails the buyer's gift to every member of their kingdom who has
// been in it long enough and has not had their day's share of gifts.
func (d Deps) sendLargesse(ctx context.Context, q *sqlcdb.Queries, buyer sqlcdb.AppPlayer,
	pr *gameconfig.Product, ref string) (rewards.Line, error) {
	if buyer.KingdomID == nil {
		return rewards.Line{}, nil
	}
	lg := pr.Largesse
	now := d.Now()
	members, err := q.LargesseRecipients(ctx, sqlcdb.LargesseRecipientsParams{
		KingdomID: buyer.KingdomID, Buyer: buyer.ID,
		JoinedBefore: now.Add(-time.Duration(lg.MinMemberHours) * time.Hour),
	})
	if err != nil {
		return rewards.Line{}, fmt.Errorf("largesse members: %w", err)
	}
	sent := 0
	for _, m := range members {
		n, err := q.CountLargesseReceived(ctx, sqlcdb.CountLargesseReceivedParams{
			PlayerID: m, Since: now.Add(-24 * time.Hour),
		})
		if err != nil {
			return rewards.Line{}, fmt.Errorf("largesse count: %w", err)
		}
		if int(n) >= lg.PerMemberPerDay {
			continue
		}
		ok, err := d.SendMail(ctx, q, m, MailDraft{
			Kind: "largesse", Sender: buyer.DisplayName,
			Title:       fmt.Sprintf("Royal Largesse from %s", buyer.DisplayName),
			Body:        fmt.Sprintf("%s has opened the royal coffers for the whole kingdom. This share is yours.", buyer.DisplayName),
			Attachments: lg.MemberGrant, IdemKey: largesseKey(ref, m),
		})
		if err != nil {
			return rewards.Line{}, err
		}
		if ok {
			sent++
		}
	}
	// The hall hears who opened the coffers. The gift itself goes by LETTER --
	// that is the one way a reward is paid, and it stays that way -- but a lord
	// who spent real money on their whole kingdom and was never named for it is
	// a lord who does it once. This is what SysLargesse was declared for, and
	// nothing had ever written one.
	if sent > 0 {
		if _, err := d.systemLine(ctx, q, *buyer.KingdomID, SysLargesse,
			fmt.Sprintf("%s opened the royal coffers. A share is on its way to %d lord%s.",
				buyer.DisplayName, sent, plural(sent)),
			map[string]any{"player_id": buyer.ID.String(), "lords": sent}); err != nil {
			return rewards.Line{}, err
		}
	}
	return rewards.Line{Kind: "largesse", Amount: int64(sent),
		Text: fmt.Sprintf("A gift sent to %d lord%s of your kingdom", sent, plural(sent)), Icon: "largesse"}, nil
}

func largesseKey(ref string, member uuid.UUID) string {
	return "largesse:" + ref + ":" + member.String()
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
