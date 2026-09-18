package gameconfig

import (
	"fmt"
	"sort"
	"strings"
)

var productKinds = map[string]bool{ProductConsumable: true, ProductNonConsumable: true, ProductSubscription: true}
var shelves = map[string]bool{ShelfDiamonds: true, ShelfOffers: true, ShelfPasses: true, ShelfComfort: true,
	ShelfKingdom: true, ShelfCharter: true}
var entitlements = map[string]bool{EntitlementSteward: true, EntitlementQuartermaster: true}
var offerTriggers = map[string]bool{TriggerLevel: true, TriggerEnergyEmpty: true, TriggerRaided: true}

// validateCommerce holds every product to FAIR and to what the store can sell.
func (b *Bundle) validateCommerce() []string {
	var p []string
	c := b.Commerce
	if len(c.Products) == 0 {
		return append(p, "commerce.products is empty — the commerce section is missing or was not generated")
	}
	if c.StorePrefix == "" || !strings.HasSuffix(c.StorePrefix, ".") {
		p = append(p, "commerce.store_prefix must be the bundle id followed by a dot")
	}
	if c.RefundFlagCount <= 0 || c.RefundFlagDays <= 0 {
		p = append(p, "commerce.refund_flag_count and refund_flag_days must be positive")
	}
	p = append(p, b.validateAds()...)

	badges := map[string]int{}
	for _, pr := range c.Products {
		where := fmt.Sprintf("commerce: product %q", pr.ID)
		if pr.ID == "" || pr.Title == "" {
			p = append(p, where+" needs an id and a title")
		}
		if !strings.HasPrefix(pr.StoreID, c.StorePrefix) || len(pr.StoreID) == len(c.StorePrefix) {
			p = append(p, fmt.Sprintf("%s: store id %q does not start with %q", where, pr.StoreID, c.StorePrefix))
		}
		if !productKinds[pr.Kind] {
			p = append(p, fmt.Sprintf("%s: unknown kind %q", where, pr.Kind))
		}
		if !shelves[pr.Shelf] {
			p = append(p, fmt.Sprintf("%s: unknown shelf %q", where, pr.Shelf))
		}
		// A zero price sells for the store's lowest tier or refuses to load in
		// App Store Connect; either way it is a typo.
		if pr.USDCents <= 0 {
			p = append(p, where+": usd_cents must be positive")
		}
		for _, problem := range b.CheckReward(pr.Grant, true) {
			p = append(p, fmt.Sprintf("%s: grant: %s", where, problem))
		}
		if pr.FirstBonusBP < 0 || pr.FirstBonusBP > 10000 {
			p = append(p, fmt.Sprintf("%s: first_bonus_bp %d is outside 0..10000", where, pr.FirstBonusBP))
		}
		if pr.FirstBonusBP > 0 && pr.Grant.Diamonds <= 0 {
			p = append(p, where+": a first-purchase bonus needs diamonds to double")
		}
		if pr.Limit < 0 || pr.FallbackDiamonds < 0 || pr.BagBonus < 0 {
			p = append(p, where+": limit, fallback_diamonds and bag_bonus cannot be negative")
		}
		// A cosmetic can already be owned when the money arrives; it then pays
		// its fallback, because money granted is never refused.
		if len(pr.Grant.Cosmetics) > 0 && pr.FallbackDiamonds <= 0 {
			p = append(p, where+": grants a cosmetic but has no fallback_diamonds for a buyer who owns it")
		}
		if pr.Badge != "" {
			if pr.Badge != "most_popular" && pr.Badge != "best_value" {
				p = append(p, fmt.Sprintf("%s: unknown badge %q", where, pr.Badge))
			}
			badges[pr.Badge]++
		}

		switch pr.Kind {
		case ProductSubscription:
			if pr.Patronage == nil {
				p = append(p, where+": a subscription needs its patronage")
				break
			}
			pa := pr.Patronage
			if pa.PeriodDiamonds <= 0 || pa.FreeRefillsPerDay < 0 || pa.BagBonus < 0 {
				p = append(p, where+": patronage needs period diamonds, and nothing negative")
			}
			for _, id := range pa.Cosmetics {
				if cm := b.Cosmetic(id); cm == nil || cm.DefaultOwned {
					p = append(p, fmt.Sprintf("%s: patronage cosmetic %q is unknown or everyone's", where, id))
				}
			}
			if !pr.Grant.Empty() {
				p = append(p, where+": a subscription pays through its patronage, not a grant")
			}
		case ProductNonConsumable:
			if !entitlements[pr.Entitlement] {
				p = append(p, fmt.Sprintf("%s: a non-consumable needs a known entitlement, not %q", where, pr.Entitlement))
			}
			if !pr.Grant.Empty() || pr.Limit > 1 {
				p = append(p, where+": a non-consumable is a lasting right, bought once, with no grant")
			}
		case ProductConsumable:
			if pr.Grant.Empty() && pr.Stipend == nil && !pr.SeasonPass {
				p = append(p, where+": a consumable must grant something")
			}
			if pr.SeasonPass && (!pr.Grant.Empty() || pr.FallbackDiamonds <= 0 || pr.Shelf != ShelfCharter) {
				p = append(p, where+": a season pass unlocks the royal lane and nothing else, on the charter shelf, "+
					"with fallback_diamonds for a season already unlocked")
			}
			if pr.Entitlement != "" || pr.Patronage != nil {
				p = append(p, where+": a consumable cannot carry an entitlement or a patronage")
			}
		}

		if s := pr.Stipend; s != nil {
			if s.Days <= 0 || s.DailyDiamonds <= 0 || s.RenewWithinDays < 0 || s.RenewWithinDays > s.Days {
				p = append(p, where+": stipend needs days and daily diamonds, and a renewal window within its days")
			}
		}
		if l := pr.Largesse; l != nil {
			if l.MemberGrant.Empty() || l.PerMemberPerDay <= 0 || l.MinMemberHours < 0 {
				p = append(p, where+": largesse needs a member grant and a daily limit")
			}
			for _, problem := range b.CheckReward(l.MemberGrant, true) {
				p = append(p, fmt.Sprintf("%s: largesse member grant: %s", where, problem))
			}
		}
		if o := pr.Offer; o != nil {
			if !offerTriggers[o.Trigger] || o.MinLevel < 1 || o.MinLevel > b.Progression.LevelCap || o.Hours <= 0 {
				p = append(p, fmt.Sprintf("%s: offer needs a known trigger, a reachable level and hours", where))
			}
			if pr.Limit != 1 {
				p = append(p, where+": an offer is sold once per account (limit 1)")
			}
		}
	}
	for badge, n := range badges {
		if n > 1 {
			p = append(p, fmt.Sprintf("commerce: %d products wear the %q ribbon; one does", n, badge))
		}
	}

	// A bigger pack never gives fewer diamonds for the money.
	var packs []Product
	for _, pr := range c.Products {
		if pr.Shelf == ShelfDiamonds {
			packs = append(packs, pr)
		}
	}
	sort.Slice(packs, func(i, k int) bool { return packs[i].USDCents < packs[k].USDCents })
	for i := 1; i < len(packs); i++ {
		a, z := packs[i-1], packs[i]
		if z.Grant.Diamonds*a.USDCents <= a.Grant.Diamonds*z.USDCents {
			p = append(p, fmt.Sprintf("commerce: %q gives no more diamonds per dollar than the cheaper %q", z.ID, a.ID))
		}
	}

	// Royal Favour climbs.
	for i, t := range c.VIP {
		if t.Level != i+1 {
			p = append(p, fmt.Sprintf("commerce.vip: level %d is out of order", t.Level))
		}
		if t.Points <= 0 || t.DailyDiamonds < 0 || t.BagBonus < 0 {
			p = append(p, fmt.Sprintf("commerce.vip: level %d needs positive points", t.Level))
		}
		if i > 0 {
			prev := c.VIP[i-1]
			if t.Points <= prev.Points || t.DailyDiamonds < prev.DailyDiamonds || t.BagBonus < prev.BagBonus {
				p = append(p, fmt.Sprintf("commerce.vip: level %d must cost more and give no less than level %d", t.Level, prev.Level))
			}
		}
		for _, id := range t.Cosmetics {
			if cm := b.Cosmetic(id); cm == nil || cm.DefaultOwned {
				p = append(p, fmt.Sprintf("commerce.vip: level %d cosmetic %q is unknown or everyone's", t.Level, id))
			}
		}
	}

	for _, cm := range b.Cosmetics.Items {
		if cm.ShopDiamonds < 0 || (cm.ShopDiamonds > 0 && cm.DefaultOwned) {
			p = append(p, fmt.Sprintf("cosmetics: %q has a shop price but is everyone's, or a negative one", cm.ID))
		}
	}
	p = append(p, b.validateDeals()...)
	return append(p, b.validateExperiments()...)
}

// validateExperiments holds each A/B test to arms that differ only in what
// they sell: offers of one slot, one trigger and one level, each product in
// one test at most.
func (b *Bundle) validateExperiments() []string {
	var p []string
	seenTest := map[string]bool{}
	seenProduct := map[string]string{}
	for _, e := range b.Commerce.Experiments {
		where := fmt.Sprintf("commerce.experiments %q", e.ID)
		if e.ID == "" || seenTest[e.ID] {
			p = append(p, where+": needs an id of its own")
		}
		seenTest[e.ID] = true
		if len(e.Arms) < 2 {
			p = append(p, where+": a test needs two arms at least")
			continue
		}
		var first *Product
		arms := map[string]bool{}
		for _, a := range e.Arms {
			if a.ID == "" || arms[a.ID] || a.Weight <= 0 {
				p = append(p, fmt.Sprintf("%s: arm %q needs an id of its own and a positive weight", where, a.ID))
			}
			arms[a.ID] = true
			pr := b.Product(a.Product)
			if pr == nil || pr.Offer == nil || pr.Offer.Slot == "" {
				p = append(p, fmt.Sprintf("%s: arm %q sells %q, which is not an offer with a slot", where, a.ID, a.Product))
				continue
			}
			if other, ok := seenProduct[a.Product]; ok {
				p = append(p, fmt.Sprintf("%s: %q is already an arm of %q", where, a.Product, other))
			}
			seenProduct[a.Product] = e.ID
			if first == nil {
				first = pr
				continue
			}
			if pr.Offer.Slot != first.Offer.Slot || pr.Offer.Trigger != first.Offer.Trigger ||
				pr.Offer.MinLevel != first.Offer.MinLevel {
				p = append(p, fmt.Sprintf("%s: arm %q is offered differently from the control (slot, trigger, level)", where, a.ID))
			}
		}
	}
	// Two offers in one slot with no test to choose between them would both show.
	slots := map[string][]string{}
	for _, pr := range b.Commerce.Products {
		if pr.Offer != nil && pr.Offer.Slot != "" {
			slots[pr.Offer.Slot] = append(slots[pr.Offer.Slot], pr.ID)
		}
	}
	for slot, ids := range slots {
		if len(ids) < 2 {
			continue
		}
		for _, id := range ids {
			if e, _ := b.ExperimentFor(id); e == nil {
				p = append(p, fmt.Sprintf("commerce: %q shares the %q slot with no test to choose between them", id, slot))
			}
		}
	}
	return p
}

// validateDeals holds the daily deals to their slots and to FAIR.
//
// The gift is free, so any reward will do. The other slots are bought with
// diamonds, and diamonds are sold: their goods keep the paid rules. A slot
// keeps its painted picture, so the potion slot holds only energy potions and
// the charter slot only Protection Charters. `was` is what the goods cost at the
// store's own prices -- a number the plate prints beside the deal's, so it is
// held to those prices rather than trusted.
func (b *Bundle) validateDeals() []string {
	var p []string
	d := b.Commerce.Deals
	store := b.Progression.Store
	firstRefill := int64(0)
	if len(store.EnergyRefillPrices) > 0 {
		firstRefill = store.EnergyRefillPrices[0]
	}
	ids := map[string]bool{}
	pool := func(name string, goods []DealGood, free bool, token string, each int64) {
		if len(goods) == 0 {
			p = append(p, fmt.Sprintf("commerce.deals.%s is empty", name))
		}
		for _, g := range goods {
			where := fmt.Sprintf("commerce.deals.%s %q", name, g.ID)
			if g.ID == "" || g.Title == "" {
				p = append(p, where+" needs an id and a title")
			}
			if ids[g.ID] {
				p = append(p, where+" repeats an id")
			}
			ids[g.ID] = true
			if g.Weight <= 0 {
				p = append(p, where+": weight must be positive")
			}
			if g.Grant.Empty() {
				p = append(p, where+": grants nothing")
			}
			for _, problem := range b.CheckReward(g.Grant, !free) {
				p = append(p, fmt.Sprintf("%s: %s", where, problem))
			}
			if free {
				if g.Diamonds != 0 || g.Was != 0 {
					p = append(p, where+": the gift is free; it has no price")
				}
				continue
			}
			if g.Diamonds <= 0 {
				p = append(p, where+": needs a price in diamonds")
			}
			// Only the slot's own goods, so the painting's picture is true.
			n := g.Grant.Tokens[token]
			others := len(g.Grant.Tokens) - 1
			if n <= 0 || others != 0 || g.Grant.Diamonds != 0 || len(g.Grant.Cosmetics) != 0 {
				p = append(p, fmt.Sprintf("%s: the %s slot sells %s tokens and nothing else", where, name, token))
			}
			if want := n * each; g.Was != want {
				p = append(p, fmt.Sprintf("%s: was %d, but %d at the store's own price is %d", where, g.Was, n, want))
			}
			if g.Diamonds >= g.Was {
				p = append(p, fmt.Sprintf("%s: a deal at %d is no cheaper than the store's %d", where, g.Diamonds, g.Was))
			}
		}
	}
	pool("gift", d.Gift, true, "", 0)
	pool("potions", d.Potions, false, "energy_potion", firstRefill)
	pool("charters", d.Charters, false, "shield_8h", store.ShieldDiamonds)
	if d.CosmeticOffBP <= 0 || d.CosmeticOffBP >= 10000 {
		p = append(p, fmt.Sprintf("commerce.deals.cosmetic_off_bp %d is outside 1..9999", d.CosmeticOffBP))
	}
	return p
}

// validateAds holds Herald's Tidings to the rule the whole store is held to.
//
// An advert is MONEY. The lord pays with their attention and the house is paid
// by the advertiser, so what an advert may hand back is exactly what a purchase
// may: diamonds, tokens, cosmetics and comfort, never gold, experience, favour,
// gear or a timed bonus. That is `CheckReward(grant, true)` and nothing else --
// there is no second list here to fall out of step with the one the store uses.
func (b *Bundle) validateAds() []string {
	var p []string
	a := b.Commerce.Ads
	where := "commerce.ads"

	if a.PerDay < 1 || a.PerDay > 20 {
		p = append(p, fmt.Sprintf("%s.per_day is %d, outside 1..20: a herald with no limit is a "+
			"diamond mine, and one with none at all is a plate that does nothing", where, a.PerDay))
	}
	if a.CooldownMinutes < 0 || a.CooldownMinutes > 24*60 {
		p = append(p, fmt.Sprintf("%s.cooldown_minutes is %d, outside a day", where, a.CooldownMinutes))
	}
	if a.MinLevel < 0 || a.MinLevel > b.Progression.LevelCap {
		p = append(p, fmt.Sprintf("%s.min_level is %d", where, a.MinLevel))
	}
	if a.TicketMinutes < 1 || a.TicketMinutes > 240 {
		p = append(p, fmt.Sprintf("%s.ticket_minutes is %d, outside 1..240: a watch that has not come "+
			"back from Google in four hours is a watch that never will", where, a.TicketMinutes))
	}
	if a.Grant.Empty() {
		p = append(p, where+".grant pays nothing, so the plate is a plate that does nothing")
	}
	// The whole rule, in one call: an advert is money.
	for _, bad := range b.CheckReward(a.Grant, true) {
		p = append(p, where+".grant: "+bad)
	}
	return p
}
