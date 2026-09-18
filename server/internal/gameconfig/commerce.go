package gameconfig

// CommerceConfig is what money buys: every App Store product, and Royal Favour.
//
// FAIR, the owner's rule: money buys time, comfort and looks -- never gold,
// never power, never a loot box. validateCommerce holds every product to it.
type CommerceConfig struct {
	// Every store id starts with this (com.emperors.game.).
	StorePrefix string    `json:"store_prefix"`
	Products    []Product `json:"products"`
	// The Royal Store's daily deals (service/deals.go).
	Deals DealsConfig `json:"deals"`
	// A/B tests on what an offer sells (service/court_store.go, admin/experiments.go).
	Experiments []Experiment `json:"experiments"`
	VIP         []VIPTier    `json:"vip"`
	// Herald's Tidings: the rewarded advert (service/ads.go).
	Ads AdsConfig `json:"ads"`
	// A player with this many refunds in this many days is flagged for the panel.
	RefundFlagCount int `json:"refund_flag_count"`
	RefundFlagDays  int `json:"refund_flag_days"`
}

// AdsConfig is Herald's Tidings: what a watched advert pays, and how often.
//
// An advert is MONEY -- the house is paid by the advertiser for the lord's
// attention -- so its grant is held to the paid rules exactly as a purchase is:
// validateAds runs CheckReward(grant, paid) over it, which refuses gold,
// experience, favour, gear and a timed bonus. Diamonds are what is left.
//
// Nothing here opens the herald. It stays SHUT until the server is given an
// AdMob unit id, because a WATCH plate over a placement with no advert to play
// is a button that does nothing.
type AdsConfig struct {
	PerDay          int `json:"per_day"`
	CooldownMinutes int `json:"cooldown_minutes"`
	MinLevel        int `json:"min_level"`
	// How long a started watch may take to come back from Google before its
	// ticket is dead.
	TicketMinutes int          `json:"ticket_minutes"`
	Grant         RewardBundle `json:"grant"`
}

// Product kinds, as the App Store sells them.
const (
	ProductConsumable    = "consumable"
	ProductNonConsumable = "non_consumable"
	ProductSubscription  = "subscription"
)

// Store shelves, which is where a product is shown.
const (
	ShelfDiamonds = "diamonds"
	ShelfOffers   = "offers"
	ShelfPasses   = "passes"
	ShelfComfort  = "comfort"
	ShelfKingdom  = "kingdom"
	// The Royal Charter's royal lane: sold on the Season Pass page, never on
	// the store's shelves.
	ShelfCharter = "charter"
)

// DealsConfig is the daily deals: four slots, each keeping its painted picture
// while what is in it rotates. A lord's four are picked once a day from these
// pools, by weight, and fixed until their next midnight.
type DealsConfig struct {
	// Slot 0, free: the gift box's possible contents.
	Gift []DealGood `json:"gift"`
	// Slot 1: energy potions, for diamonds.
	Potions []DealGood `json:"potions"`
	// Slot 2: Protection Charters, for diamonds.
	Charters []DealGood `json:"charters"`
	// Slot 3: a cosmetic the Splendour shop sells that the lord does not own,
	// this much off its shop price.
	CosmeticOffBP int64 `json:"cosmetic_off_bp"`
}

// DealGood is one thing a deal slot can hold.
type DealGood struct {
	ID    string       `json:"id"`
	Title string       `json:"title"`
	Grant RewardBundle `json:"grant"`
	// The price in diamonds; zero for the free gift.
	Diamonds int64 `json:"diamonds,omitempty"`
	// What the same goods cost at the store's own prices, for the plate to say
	// what the deal saves. Validate holds it to those prices.
	Was    int64 `json:"was,omitempty"`
	Weight int   `json:"weight"`
}

// Product is one thing the App Store sells.
type Product struct {
	ID       string `json:"id"`
	StoreID  string `json:"store_id"`
	Kind     string `json:"kind"`
	USDCents int64  `json:"usd_cents"`
	Shelf    string `json:"shelf"`
	Title    string `json:"title"`
	// "most_popular" or "best_value", for the store's ribbons.
	Badge string `json:"badge,omitempty"`

	// What one purchase pays, through grantBundle, marked paid.
	Grant RewardBundle `json:"grant"`
	// The first purchase of this product pays this much more of Grant.Diamonds
	// (10000 = double), once per account.
	FirstBonusBP int64 `json:"first_bonus_bp,omitempty"`
	// How many one account may buy; zero is no limit.
	Limit int `json:"limit,omitempty"`
	// Paid instead, in diamonds, for anything in Grant that cannot be delivered
	// when the money arrives (a cosmetic already owned). Money granted is never
	// refused at the moment of grant.
	FallbackDiamonds int64 `json:"fallback_diamonds,omitempty"`

	// A non-consumable's lasting right: "steward" or "quartermaster".
	Entitlement string `json:"entitlement,omitempty"`
	// Bag slots a non-consumable adds for good.
	BagBonus int `json:"bag_bonus,omitempty"`

	// Unlocks the Royal Charter's royal lane for the season it is bought in
	// (liveops.season.royal_product). It grants nothing else; bought again in
	// a season already unlocked, it pays its fallback_diamonds.
	SeasonPass bool `json:"season_pass,omitempty"`

	Stipend   *StipendConfig   `json:"stipend,omitempty"`
	Patronage *PatronageConfig `json:"patronage,omitempty"`
	Largesse  *LargesseConfig  `json:"largesse,omitempty"`
	Offer     *OfferConfig     `json:"offer,omitempty"`
}

// Entitlements a non-consumable can grant.
const (
	EntitlementSteward       = "steward"
	EntitlementQuartermaster = "quartermaster"
)

// StipendConfig is the Royal Stipend: diamonds now, then a share each day for a
// month, to be claimed on the day or lost.
type StipendConfig struct {
	Days          int   `json:"days"`
	DailyDiamonds int64 `json:"daily_diamonds"`
	// A stipend may be bought again once this few days are left.
	RenewWithinDays int `json:"renew_within_days"`
}

// PatronageConfig is Crown Patronage, the monthly subscription. Every field is
// a fixed comfort; none is a bonus in any bucket.
type PatronageConfig struct {
	// Paid at the start of every period, the first and each renewal.
	PeriodDiamonds    int64 `json:"period_diamonds"`
	FreeRefillsPerDay int   `json:"free_refills_per_day"`
	BagBonus          int   `json:"bag_bonus"`
	Steward           bool  `json:"steward"`
	// SkipAds is the plan's "reklam atlama", and NOTHING READS IT -- deliberately.
	// The game's only advert is Herald's Tidings: opt-in, in the Royal Store, and
	// it PAYS the lord who watches it (commerce.ads). There is no interstitial to
	// skip and none is planned, so honouring this would mean taking 70 diamonds a
	// week away from the one player who paid -- a punishment for paying, which is
	// the opposite of what the line was for. Left in place because it is the
	// owner's to spend if unsolicited adverts ever exist; until then it promises
	// the player nothing, says nothing on the patronage plate, and must not be
	// implemented on the strength of its own name.
	SkipAds bool `json:"skip_ads"`
	// Worn while the patronage lasts.
	Cosmetics []string `json:"cosmetics"`
}

// LargesseConfig is Royal Largesse: a gift to the buyer's whole kingdom.
type LargesseConfig struct {
	MemberGrant     RewardBundle `json:"member_grant"`
	PerMemberPerDay int          `json:"per_member_per_day"`
	MinMemberHours  int          `json:"min_member_hours"`
}

// OfferConfig is when an offer appears: at a level, when the energy runs out
// with the day's refills gone, or after a raid on the player.
type OfferConfig struct {
	Trigger  string `json:"trigger"`
	MinLevel int    `json:"min_level"`
	Hours    int    `json:"hours"`
	// Offers in one slot are one offer: an A/B test's arms, of which a lord is
	// shown one. "starter" is the Founder's Crate, shown beside the best level
	// offer rather than competing with it.
	Slot string `json:"slot,omitempty"`
}

// Experiment is an A/B test on what an offer sells.
type Experiment struct {
	ID     string `json:"id"`
	Active bool   `json:"active"`
	Note   string `json:"note"`
	// The first arm is the control: what everyone sees while the test is off.
	Arms []ExperimentArm `json:"arms"`
}

// ExperimentArm is one side of a test: its share of lords and its product.
type ExperimentArm struct {
	ID      string `json:"id"`
	Weight  int    `json:"weight"`
	Product string `json:"product"`
}

// ExperimentFor returns the test a product is an arm of, and the arm; nil when
// it is in none.
func (b *Bundle) ExperimentFor(productID string) (*Experiment, *ExperimentArm) {
	for i := range b.Commerce.Experiments {
		e := &b.Commerce.Experiments[i]
		for k := range e.Arms {
			if e.Arms[k].Product == productID {
				return e, &e.Arms[k]
			}
		}
	}
	return nil, nil
}

// Offer triggers.
const (
	TriggerLevel       = "level"
	TriggerEnergyEmpty = "energy_empty"
	TriggerRaided      = "raided"
)

// VIPTier is one level of Royal Favour.
type VIPTier struct {
	Level int `json:"level"`
	// US cents spent to reach it.
	Points        int64    `json:"points"`
	DailyDiamonds int64    `json:"daily_diamonds"`
	BagBonus      int      `json:"bag_bonus"`
	Cosmetics     []string `json:"cosmetics"`
}

// Product returns the product with this id, or nil.
func (b *Bundle) Product(id string) *Product { return b.productByID[id] }

// ProductByStoreID returns the product the App Store calls this, or nil.
func (b *Bundle) ProductByStoreID(storeID string) *Product { return b.productByStore[storeID] }

// VIPLevel is the Royal Favour level these points reach: 0 below the first.
func (b *Bundle) VIPLevel(points int64) int {
	level := 0
	for _, t := range b.Commerce.VIP {
		if points >= t.Points {
			level = t.Level
		}
	}
	return level
}

// VIPTier returns a level's tier, or nil for level 0.
func (b *Bundle) VIPTier(level int) *VIPTier {
	for i := range b.Commerce.VIP {
		if b.Commerce.VIP[i].Level == level {
			return &b.Commerce.VIP[i]
		}
	}
	return nil
}
