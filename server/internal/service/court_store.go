package service

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/experiments"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The Royal Store, as one lord sees it: what is on sale to them now, what each
// purchase would bring, and where they stand with Royal Favour, the Stipend and
// Crown Patronage. Prices are the App Store's -- the phone asks StoreKit for each
// product's price in the player's own currency -- so nothing here is money.

// StoreProduct is one product on the lord's shelves.
type StoreProduct struct {
	ID      string `json:"id"`
	StoreID string `json:"store_id"`
	Kind    string `json:"kind"`
	Shelf   string `json:"shelf"`
	Title   string `json:"title"`
	Badge   string `json:"badge,omitempty"`
	// The catalogue's price tier in US cents. A reference only: what a buyer
	// pays is StoreKit's localized price, and the client shows this one, dimmed,
	// only where purchases cannot be made at all.
	USDCents int64 `json:"usd_cents"`
	// What the next purchase brings, the first-purchase bonus included.
	Lines      []rewards.Line `json:"lines"`
	FirstBonus bool           `json:"first_bonus"`
	// Whether it can be bought now, and if not, why not (in words to show).
	Available bool   `json:"available"`
	Note      string `json:"note,omitempty"`
	// An offer's time left, in seconds; 0 for anything that is not an offer.
	EndsIn int64 `json:"ends_in,omitempty"`
	Owned  bool  `json:"owned,omitempty"`
}

// CourtStore is the whole Royal Store for one lord.
type CourtStore struct {
	Products  []StoreProduct `json:"products"`
	VIP       VIPView        `json:"vip"`
	Stipend   StipendView    `json:"stipend"`
	Patronage PatronView     `json:"patronage"`
	Steward   bool           `json:"steward"`
	// The day's four deals (deals.go).
	Deals DealsView `json:"deals"`
	// Herald's Tidings, the rewarded advert (ads.go). Shut until this server
	// is given an advert unit to play.
	Herald HeraldView `json:"herald"`
}

// VIPView is Royal Favour, for the lord's own eyes: the level and how far to
// the next. Other lords see only the seal.
type VIPView struct {
	Level      int   `json:"level"`
	Points     int64 `json:"points"`
	NextLevel  int   `json:"next_level,omitempty"`
	NextPoints int64 `json:"next_points,omitempty"`
	// Today's gift, and whether it waits.
	GiftDiamonds  int64         `json:"gift_diamonds"`
	GiftClaimable bool          `json:"gift_claimable"`
	Tiers         []VIPTierView `json:"tiers"`
}

// VIPTierView is one level of Royal Favour and what it brings.
type VIPTierView struct {
	Level         int            `json:"level"`
	Points        int64          `json:"points"`
	DailyDiamonds int64          `json:"daily_diamonds"`
	BagBonus      int            `json:"bag_bonus"`
	Cosmetics     []rewards.Line `json:"cosmetics"`
}

// StipendView is the Royal Stipend's state.
type StipendView struct {
	Active         bool  `json:"active"`
	DaysLeft       int   `json:"days_left"`
	ClaimableToday bool  `json:"claimable_today"`
	DailyDiamonds  int64 `json:"daily_diamonds"`
}

// PatronView is Crown Patronage's state.
type PatronView struct {
	Active  bool  `json:"active"`
	Seconds int64 `json:"seconds"`
}

// GetCourtStore builds the store for one lord, firing any offer whose moment
// has come (a level reached while they were away counts when they next look).
func (d Deps) GetCourtStore(ctx context.Context, playerID uuid.UUID) (*CourtStore, error) {
	var out *CourtStore
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("load player: %w", err)
		}
		if err := d.fireLevelOffers(ctx, q, p); err != nil {
			return err
		}
		out, err = d.courtStore(ctx, q, p)
		return err
	})
	return out, err
}

func (d Deps) courtStore(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*CourtStore, error) {
	now := d.Now()
	today := localDay(now, p.ResetOffsetMinutes)
	counts := map[string]int{}
	rows, err := q.ListPurchaseCounts(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("purchase counts: %w", err)
	}
	for _, r := range rows {
		counts[r.ProductID] = int(r.Bought)
	}
	offers := map[string]sqlcdb.AppPlayerOffer{}
	ofs, err := q.ListOffers(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("offers: %w", err)
	}
	for _, o := range ofs {
		offers[o.ProductID] = o
	}
	owned := map[string]bool{}
	ents, err := q.ListEntitlements(ctx, p.ID)
	if err != nil {
		return nil, fmt.Errorf("entitlements: %w", err)
	}
	for _, e := range ents {
		owned[e.Entitlement] = true
	}
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}

	cs := &CourtStore{Products: []StoreProduct{}, Steward: d.stewardActive(p, now)}
	for i := range d.Config.Commerce.Products {
		pr := &d.Config.Commerce.Products[i]
		// The Royal Charter is sold on the Season Pass page, not the store's shelves.
		if pr.Shelf == gameconfig.ShelfCharter {
			continue
		}
		sp := StoreProduct{ID: pr.ID, StoreID: pr.StoreID, Kind: pr.Kind, Shelf: pr.Shelf,
			Title: pr.Title, Badge: pr.Badge, USDCents: pr.USDCents, Available: true, Lines: []rewards.Line{}}
		b := pr.Grant
		if pr.FirstBonusBP > 0 && counts[pr.ID] == 0 {
			b.Diamonds += b.Diamonds * pr.FirstBonusBP / 10000
			sp.FirstBonus = true
		}
		if !b.Empty() {
			sp.Lines = rewards.Lines(d.Config, b, rewards.Resolve(d.Config, b, int(p.Level), eff.Bonuses))
		}

		switch {
		case pr.Offer != nil:
			o, fired := offers[pr.ID]
			if !fired || !o.ExpiresAt.After(now) || counts[pr.ID] >= max1(pr.Limit) {
				continue
			}
			sp.EndsIn = int64(o.ExpiresAt.Sub(now) / time.Second)
		case pr.Limit > 0 && counts[pr.ID] >= pr.Limit:
			sp.Available, sp.Note = false, "already bought"
		}

		switch {
		case pr.Entitlement != "":
			if owned[pr.Entitlement] {
				sp.Owned, sp.Available, sp.Note = true, false, "yours for good"
			}
			sp.Lines = append(sp.Lines, entitlementLine(pr))
		case pr.Patronage != nil:
			if patronActive(p, now) {
				sp.Available, sp.Note = false, "you are a patron"
			}
			sp.Lines = append(sp.Lines, rewards.Line{Kind: "diamonds", Amount: pr.Patronage.PeriodDiamonds,
				Text: fmt.Sprintf("%d diamonds each month", pr.Patronage.PeriodDiamonds), Icon: "diamond"},
				rewards.Line{Kind: "patronage", Amount: int64(pr.Patronage.FreeRefillsPerDay),
					Text: fmt.Sprintf("%d free energy refill each day", pr.Patronage.FreeRefillsPerDay), Icon: "energy_potion"},
				rewards.Line{Kind: "patronage", Amount: int64(pr.Patronage.BagBonus),
					Text: fmt.Sprintf("+%d bag slots", pr.Patronage.BagBonus), Icon: "quartermaster"})
			if pr.Patronage.Steward {
				sp.Lines = append(sp.Lines, rewards.Line{Kind: "patronage", Amount: 1,
					Text: "The Steward keeps your house", Icon: "steward"})
			}
			// The patron's looks, worn while it lasts: one line, as the Favour
			// painting has a row for each perk.
			if l, ok := patronLooksLine(d.Config, pr.Patronage.Cosmetics); ok {
				sp.Lines = append(sp.Lines, l)
			}
		case pr.Stipend != nil:
			left := stipendDaysLeft(p, today)
			if left > pr.Stipend.RenewWithinDays {
				sp.Available, sp.Note = false, fmt.Sprintf("renews when %d days are left", pr.Stipend.RenewWithinDays)
			}
			sp.Lines = append(sp.Lines, rewards.Line{Kind: "stipend", Amount: pr.Stipend.DailyDiamonds,
				Text: fmt.Sprintf("then %d diamonds a day for %d days", pr.Stipend.DailyDiamonds, pr.Stipend.Days),
				Icon: "diamond"})
		case pr.Largesse != nil:
			if p.KingdomID == nil {
				sp.Available, sp.Note = false, "join a kingdom to give Largesse"
			}
			sp.Lines = append(sp.Lines, rewards.Line{Kind: "largesse", Amount: pr.Largesse.MemberGrant.Diamonds,
				Text: fmt.Sprintf("and %d diamonds to every lord of your kingdom", pr.Largesse.MemberGrant.Diamonds),
				Icon: "largesse"})
		}
		cs.Products = append(cs.Products, sp)
	}
	sort.SliceStable(cs.Products, func(i, k int) bool {
		return shelfOrder[cs.Products[i].Shelf] < shelfOrder[cs.Products[k].Shelf]
	})

	cs.VIP = d.vipView(p, today)
	if st := d.stipendConfig(); st != nil {
		left := stipendDaysLeft(p, today)
		cs.Stipend = StipendView{Active: left > 0, DaysLeft: left, DailyDiamonds: st.DailyDiamonds,
			ClaimableToday: left > 0 && (!p.StipendClaimed.Valid || p.StipendClaimed.Time.Before(today))}
	}
	if patronActive(p, now) {
		cs.Patronage = PatronView{Active: true, Seconds: int64(p.PatronUntil.Sub(now) / time.Second)}
	}
	cs.Herald = d.herald(ctx, q, p)
	if cs.Deals, err = d.dealsView(ctx, q, p); err != nil {
		return nil, err
	}
	return cs, nil
}

// patronLooksLine says the patronage's cosmetics in one line: "Patron's Frame
// and Patron's Gold name colour, while it lasts". Drawn with the first one's
// art; a name colour's hex rides along for a chip.
func patronLooksLine(cfg *gameconfig.Bundle, ids []string) (rewards.Line, bool) {
	var words []string
	line := rewards.Line{Kind: "patronage", Amount: 1}
	for _, id := range ids {
		c := cfg.Cosmetic(id)
		if c == nil {
			continue
		}
		name := c.Name
		switch c.Kind {
		case gameconfig.CosmeticNameColor:
			name += " name colour"
			line.Color = c.Color
		case gameconfig.CosmeticTitle:
			name = "the title " + c.Text
		default:
			if kind := rewards.CosmeticKindWord(c.Kind); !strings.Contains(strings.ToLower(name), kind) {
				name += " " + kind
			}
		}
		words = append(words, name)
		if line.Icon == "" {
			line.ID, line.Icon = c.ID, c.Kind+":"+c.ID
			if c.Art != "" {
				line.Icon = c.Art
			}
		}
	}
	if len(words) == 0 {
		return rewards.Line{}, false
	}
	joined := words[0]
	if n := len(words); n > 1 {
		joined = strings.Join(words[:n-1], ", ") + " and " + words[n-1]
	}
	line.Text = joined + ", while it lasts"
	return line, true
}

// Shelves in the order the store shows them.
var shelfOrder = map[string]int{
	gameconfig.ShelfOffers: 0, gameconfig.ShelfDiamonds: 1, gameconfig.ShelfPasses: 2,
	gameconfig.ShelfComfort: 3, gameconfig.ShelfKingdom: 4,
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func (d Deps) vipView(p sqlcdb.AppPlayer, today time.Time) VIPView {
	lvl := d.vipLevel(p)
	v := VIPView{Level: lvl, Points: p.VipPoints, Tiers: []VIPTierView{}}
	if t := d.Config.VIPTier(lvl); t != nil {
		v.GiftDiamonds = t.DailyDiamonds
		v.GiftClaimable = t.DailyDiamonds > 0 && (!p.VipGiftOn.Valid || p.VipGiftOn.Time.Before(today))
	}
	if nt := d.Config.VIPTier(lvl + 1); nt != nil {
		v.NextLevel, v.NextPoints = nt.Level, nt.Points
	}
	for _, t := range d.Config.Commerce.VIP {
		tv := VIPTierView{Level: t.Level, Points: t.Points, DailyDiamonds: t.DailyDiamonds,
			BagBonus: t.BagBonus, Cosmetics: []rewards.Line{}}
		if len(t.Cosmetics) > 0 {
			b := gameconfig.RewardBundle{Cosmetics: t.Cosmetics}
			tv.Cosmetics = rewards.Lines(d.Config, b, rewards.Resolved{})
		}
		v.Tiers = append(v.Tiers, tv)
	}
	return v
}

func (d Deps) stipendConfig() *gameconfig.StipendConfig {
	for i := range d.Config.Commerce.Products {
		if st := d.Config.Commerce.Products[i].Stipend; st != nil {
			return st
		}
	}
	return nil
}

// stipendDaysLeft counts today and the days after it the stipend still pays.
func stipendDaysLeft(p sqlcdb.AppPlayer, today time.Time) int {
	if !p.StipendUntil.Valid || p.StipendUntil.Time.Before(today) {
		return 0
	}
	return int(p.StipendUntil.Time.Sub(today).Hours()/24) + 1
}

// shownOffers is what a lord has already been shown: each offer's product,
// and each slot one of whose offers they have had. A slot is one offer (an A/B
// test's arms), so a lord who has had one arm is never shown another, even
// when the test is later switched on or off.
type shownOffers struct {
	products map[string]bool
	slots    map[string]bool
}

func (d Deps) offersShown(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (shownOffers, error) {
	ofs, err := q.ListOffers(ctx, playerID)
	if err != nil {
		return shownOffers{}, fmt.Errorf("offers: %w", err)
	}
	return d.shownFrom(ofs), nil
}

func (d Deps) shownFrom(ofs []sqlcdb.AppPlayerOffer) shownOffers {
	s := shownOffers{products: map[string]bool{}, slots: map[string]bool{}}
	for _, o := range ofs {
		s.mark(d.Config.Product(o.ProductID), o.ProductID)
	}
	return s
}

func (s shownOffers) mark(pr *gameconfig.Product, id string) {
	s.products[id] = true
	if pr != nil && pr.Offer != nil && pr.Offer.Slot != "" {
		s.slots[pr.Offer.Slot] = true
	}
}

// due reports whether an offer is still this lord's to be shown: not shown
// already, its slot not yet had, and, for an arm of a test, their own arm.
func (d Deps) due(playerID uuid.UUID, pr *gameconfig.Product, s shownOffers) bool {
	if s.products[pr.ID] || (pr.Offer.Slot != "" && s.slots[pr.Offer.Slot]) {
		return false
	}
	return d.armShown(playerID, pr)
}

// levelOffersDue is which level offers a lord has reached and not been shown.
// A lord past several at once (they reached level 30 before offers existed) is
// shown the slotted ones (the Founder's Crate) and the best level offer they
// qualify for; the ones passed over are lapsed, recorded as shown and already
// over, so a lord is never shown four offers at once.
func (d Deps) levelOffersDue(p sqlcdb.AppPlayer, s shownOffers) (fire, lapse []*gameconfig.Product) {
	var best *gameconfig.Product
	for i := range d.Config.Commerce.Products {
		pr := &d.Config.Commerce.Products[i]
		if pr.Offer == nil || pr.Offer.Trigger != gameconfig.TriggerLevel || int(p.Level) < pr.Offer.MinLevel {
			continue
		}
		if pr.Offer.Slot != "" {
			if d.due(p.ID, pr, s) {
				fire = append(fire, pr)
				s.mark(pr, pr.ID)
			}
			continue
		}
		switch {
		case best == nil:
			best = pr
		case pr.Offer.MinLevel > best.Offer.MinLevel:
			lapse = append(lapse, best)
			best = pr
		default:
			lapse = append(lapse, pr)
		}
	}
	if best != nil {
		fire = append(fire, best)
	}
	// What was shown before stays as it was.
	keep := func(list []*gameconfig.Product) []*gameconfig.Product {
		out := list[:0]
		for _, pr := range list {
			if pr.Offer.Slot != "" || !s.products[pr.ID] {
				out = append(out, pr)
			}
		}
		return out
	}
	return keep(fire), keep(lapse)
}

// fireLevelOffers fires the level offers a lord has reached (see
// levelOffersDue).
func (d Deps) fireLevelOffers(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) error {
	s, err := d.offersShown(ctx, q, p.ID)
	if err != nil {
		return err
	}
	now := d.Now()
	fire, lapse := d.levelOffersDue(p, s)
	for _, pr := range fire {
		if err := d.fireOffer(ctx, q, p.ID, pr, now); err != nil {
			return err
		}
	}
	for _, pr := range lapse {
		if _, err := q.FireOffer(ctx, sqlcdb.FireOfferParams{
			PlayerID: p.ID, ProductID: pr.ID, FiredAt: now, ExpiresAt: now,
		}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("lapse offer: %w", err)
		}
	}
	return nil
}

// armShown reports whether a lord is shown this offer. A product in no test
// always is; an arm of a test only when it is the lord's arm -- the control,
// its first, while the test is off.
func (d Deps) armShown(playerID uuid.UUID, pr *gameconfig.Product) bool {
	e, _ := d.Config.ExperimentFor(pr.ID)
	if e == nil {
		return true
	}
	return d.armOf(playerID, e).Product == pr.ID
}

// armOf is the arm of a test a lord is in: the control while the test is off.
func (d Deps) armOf(playerID uuid.UUID, e *gameconfig.Experiment) gameconfig.ExperimentArm {
	if !e.Active {
		return e.Arms[0]
	}
	arms := make([]experiments.Arm, len(e.Arms))
	for i, a := range e.Arms {
		arms[i] = experiments.Arm{ID: a.ID, Weight: a.Weight}
	}
	id := experiments.Assign(d.ShopSecret, e.ID, playerID.String(), arms)
	for _, a := range e.Arms {
		if a.ID == id {
			return a
		}
	}
	return e.Arms[0]
}

// fireOffer opens an offer's window, once per account. An arm of a running
// test counts the lord as shown it, in the same transaction.
func (d Deps) fireOffer(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, pr *gameconfig.Product, now time.Time) error {
	_, err := q.FireOffer(ctx, sqlcdb.FireOfferParams{
		PlayerID: playerID, ProductID: pr.ID, FiredAt: now,
		ExpiresAt: now.Add(time.Duration(pr.Offer.Hours) * time.Hour),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // shown before
	}
	if err != nil {
		return fmt.Errorf("fire offer %s: %w", pr.ID, err)
	}
	if e, arm := d.Config.ExperimentFor(pr.ID); e != nil && e.Active {
		if err := q.RecordExposure(ctx, sqlcdb.RecordExposureParams{
			Experiment: e.ID, PlayerID: playerID, Arm: arm.ID, ProductID: pr.ID, At: now,
		}); err != nil {
			return fmt.Errorf("record exposure: %w", err)
		}
	}
	return nil
}

// fireMomentOffers opens the offers a moment calls for (the day's refills
// gone, a raid suffered) that a lord of this level is due.
func (d Deps) fireMomentOffers(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, level int32, trigger string, now time.Time) error {
	s, err := d.offersShown(ctx, q, playerID)
	if err != nil {
		return err
	}
	for i := range d.Config.Commerce.Products {
		pr := &d.Config.Commerce.Products[i]
		if pr.Offer == nil || pr.Offer.Trigger != trigger || int(level) < pr.Offer.MinLevel || !d.due(playerID, pr, s) {
			continue
		}
		if err := d.fireOffer(ctx, q, playerID, pr, now); err != nil {
			return err
		}
		s.mark(pr, pr.ID)
	}
	return nil
}

// fireTriggerOffer opens the offers a moment calls for in its own small
// transaction: the moment is usually a refusal, whose own transaction has
// already rolled back.
func (d Deps) fireTriggerOffer(ctx context.Context, playerID uuid.UUID, trigger string) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.GetPlayerByID(ctx, playerID)
		if err != nil {
			return err
		}
		return d.fireMomentOffers(ctx, q, playerID, p.Level, trigger, d.Now())
	})
	if err != nil {
		d.logSoftStep("offer "+trigger, err)
	}
}

// activeOffers counts the offers a lord has not yet seen, for the badge.
func activeOffers(offers []sqlcdb.AppPlayerOffer, now time.Time) (active, unseen int) {
	for _, o := range offers {
		if o.ExpiresAt.After(now) {
			active++
			if o.SeenAt == nil {
				unseen++
			}
		}
	}
	return active, unseen
}

// SeeOffers marks the lord's live offers as seen, once the popup has shown them.
func (d Deps) SeeOffers(ctx context.Context, playerID uuid.UUID) error {
	now := d.Now()
	return sqlcdb.New(d.Pool).MarkOffersSeen(ctx, sqlcdb.MarkOffersSeenParams{PlayerID: playerID, At: &now})
}

// ClaimResult is what a daily claim paid.
type ClaimResult struct {
	Diamonds int64     `json:"diamonds"`
	Snapshot *Snapshot `json:"snapshot"`
}

var ErrNothingToClaim = errors.New("there is nothing to claim today")

// ClaimStipend claims today's Royal Stipend share. No action_seq: a daily claim
// is claimed once by its own row, and moves nothing a queued collect reads.
func (d Deps) ClaimStipend(ctx context.Context, playerID uuid.UUID) (*ClaimResult, error) {
	st := d.stipendConfig()
	if st == nil {
		return nil, ErrNotFound
	}
	var paid int64
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		paid, err = d.claimStipend(ctx, q, &p, st)
		return err
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	return &ClaimResult{Diamonds: paid, Snapshot: snap}, err
}

func (d Deps) claimStipend(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, st *gameconfig.StipendConfig) (int64, error) {
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	claimed, err := q.ClaimStipendDay(ctx, sqlcdb.ClaimStipendDayParams{ID: p.ID, Today: dateOf(today)})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNothingToClaim
	}
	if err != nil {
		return 0, fmt.Errorf("claim stipend: %w", err)
	}
	ref := ""
	if claimed.StipendRef != nil {
		ref = *claimed.StipendRef
	}
	after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: st.DailyDiamonds})
	if err != nil {
		return 0, fmt.Errorf("stipend diamonds: %w", err)
	}
	if err := ledger.Diamonds(ctx, q, claimed, after, st.DailyDiamonds, ledger.Stipend, ref); err != nil {
		return 0, err
	}
	*p = after
	return st.DailyDiamonds, nil
}

// ClaimVIPGift claims today's Royal Favour gift.
func (d Deps) ClaimVIPGift(ctx context.Context, playerID uuid.UUID) (*ClaimResult, error) {
	var paid int64
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		paid, err = d.claimVIPGift(ctx, q, &p)
		return err
	})
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	return &ClaimResult{Diamonds: paid, Snapshot: snap}, err
}

func (d Deps) claimVIPGift(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer) (int64, error) {
	t := d.Config.VIPTier(d.vipLevel(*p))
	if t == nil || t.DailyDiamonds <= 0 {
		return 0, ErrNothingToClaim
	}
	today := localDay(d.Now(), p.ResetOffsetMinutes)
	claimed, err := q.ClaimVIPGift(ctx, sqlcdb.ClaimVIPGiftParams{ID: p.ID, Today: dateOf(today)})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNothingToClaim
	}
	if err != nil {
		return 0, fmt.Errorf("claim favour gift: %w", err)
	}
	after, err := q.CreditDiamonds(ctx, sqlcdb.CreditDiamondsParams{ID: p.ID, Amount: t.DailyDiamonds})
	if err != nil {
		return 0, fmt.Errorf("favour gift diamonds: %w", err)
	}
	if err := ledger.Diamonds(ctx, q, claimed, after, t.DailyDiamonds, ledger.VIPGift, today.Format("2006-01-02")); err != nil {
		return 0, err
	}
	*p = after
	return t.DailyDiamonds, nil
}

// dateOf is a calendar day as the database takes it.
func dateOf(day time.Time) pgtype.Date { return pgtype.Date{Time: day, Valid: true} }
