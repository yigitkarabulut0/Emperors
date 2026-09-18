package gameconfig

// RewardsConfig is the reward machinery's own data: what each token is, how long
// a letter lasts, and the bounds every reward must stay inside.
type RewardsConfig struct {
	Tokens   []TokenDef     `json:"tokens"`
	Mail     MailConfig     `json:"mail"`
	Limits   RewardLimits   `json:"limits"`
	Promo    PromoConfig    `json:"promo"`
	Referral ReferralConfig `json:"referral"`
}

// PromoConfig bounds the panel's promo codes (service/promo.go). A code gives
// only what play gives too: App Review 3.1.1 forbids a code that unlocks what
// is sold, so no cosmetics and a handful of diamonds at most.
type PromoConfig struct {
	MaxDiamonds int64 `json:"max_diamonds"`
	// Wrong codes a lord may try in an hour before the next is refused.
	FailuresPerHour int `json:"failures_per_hour"`
	// How long a promo letter waits in the Royal Mail.
	ExpiryDays int `json:"expiry_days"`
}

// ReferralConfig is bringing a friend (service/referral.go).
type ReferralConfig struct {
	// Both are paid when the friend reaches this level.
	RewardLevel     int   `json:"reward_level"`
	InviteeDiamonds int64 `json:"invitee_diamonds"`
	InviterDiamonds int64 `json:"inviter_diamonds"`
	// A friend enters a code within this many days of joining.
	ClaimDays int `json:"claim_days"`
	// A lord whose account is younger cannot be named as the one who invited.
	InviterMinHours int `json:"inviter_min_hours"`
	// How many friends may name one lord in a day, and be paid for in all.
	LinksPerDay  int `json:"links_per_day"`
	RewardsTotal int `json:"rewards_total"`
}

// TokenDef is one kind of consumable a player can hold a count of.
type TokenDef struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Blurb string `json:"blurb"`
	// Icon is a semantic art key the client maps to a painted crop.
	Icon string `json:"icon"`
	// PaidOK marks a token money may carry. False for anything whose use rolls
	// for loot: sold, that would be a paid loot box, which this game never has.
	PaidOK bool `json:"paid_ok"`
	// EnergyPct is what a flask restores, as a share of the lord's own pool.
	// Only a token money never carries may restore energy: bought energy is the
	// day's refills and nothing more.
	EnergyPct int64 `json:"energy_pct,omitempty"`
}

// MailConfig is the Royal Mail's housekeeping.
type MailConfig struct {
	// How long a letter stays claimable when its sender does not say.
	DefaultExpiryDays int `json:"default_expiry_days"`
	// How long after expiry a letter is kept before it is deleted.
	PurgeAfterDays int `json:"purge_after_days"`
	// The newest letters the inbox shows.
	InboxLimit int `json:"inbox_limit"`
	// The most letters one CLAIM ALL opens.
	ClaimAllMax int `json:"claim_all_max"`
}

// RewardLimits bound a single reward, so a typo in a letter or a balance field
// is refused rather than delivered.
type RewardLimits struct {
	MaxDiamonds   int64 `json:"max_diamonds"`
	MaxGold       int64 `json:"max_gold"`
	MaxXP         int64 `json:"max_xp"`
	MaxWages      int64 `json:"max_wages_energy"`
	MaxFavour     int64 `json:"max_favour"`
	MaxItems      int   `json:"max_items"`
	MaxTokens     int64 `json:"max_tokens"`
	MaxBoostHours int64 `json:"max_boost_hours"`
}

// ItemGrant is gear granted by a reward: rolled at the player's own level when
// it is granted, never at a level written into the reward.
type ItemGrant struct {
	// weapon, armor or horse; empty rolls one at random.
	Slot  string `json:"slot,omitempty"`
	Tier  string `json:"tier"`
	Count int    `json:"count"`
}

// BoostGrant is a timed bonus owned by one player. Always the timed lane.
type BoostGrant struct {
	// collect_income_bp, xp_bp (their buckets' timed lanes) or luck_bp (added
	// to the lord's luck, clamped with the rest of it).
	Bucket string `json:"bucket"`
	BP     int64  `json:"bp"`
	Hours  int64  `json:"hours"`
}

// RewardBundle is everything one reward can carry. Every system pays through it.
type RewardBundle struct {
	Diamonds int64 `json:"diamonds,omitempty"`
	Gold     int64 `json:"gold,omitempty"`
	XP       int64 `json:"xp,omitempty"`
	// Wages are paid in ENERGY: what that much energy earns at the best job the
	// player can do, so one reward is worth the same share of a day's play at
	// level 5 and at level 55. Gold goes through the collect bucket's permanent
	// lane, experience through the XP bucket, as any new source of either must.
	GoldWages int64            `json:"gold_wages,omitempty"`
	XPWages   int64            `json:"xp_wages,omitempty"`
	Favour    int64            `json:"favour,omitempty"`
	Tokens    map[string]int64 `json:"tokens,omitempty"`
	Items     []ItemGrant      `json:"items,omitempty"`
	Cosmetics []string         `json:"cosmetics,omitempty"`
	Boosts    []BoostGrant     `json:"boosts,omitempty"`
}

// Empty reports a bundle that grants nothing.
func (r RewardBundle) Empty() bool {
	return r.Diamonds == 0 && r.Gold == 0 && r.XP == 0 && r.GoldWages == 0 && r.XPWages == 0 &&
		r.Favour == 0 && len(r.Tokens) == 0 && len(r.Items) == 0 && len(r.Cosmetics) == 0 &&
		len(r.Boosts) == 0
}

// Token returns the token with this id, or nil.
func (b *Bundle) Token(id string) *TokenDef {
	for i := range b.Rewards.Tokens {
		if b.Rewards.Tokens[i].ID == id {
			return &b.Rewards.Tokens[i]
		}
	}
	return nil
}

// CosmeticsConfig is every portrait frame, title, name colour and crest.
type CosmeticsConfig struct {
	Items []Cosmetic `json:"items"`
}

// Cosmetic kinds. One of each can be worn.
const (
	CosmeticFrame     = "frame"
	CosmeticTitle     = "title"
	CosmeticNameColor = "name_color"
	CosmeticCrest     = "crest"
)

// Cosmetic is one way a lord can look. It never changes how they fight.
type Cosmetic struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	Name string `json:"name"`
	// Title text shown under the name, for a title.
	Text string `json:"text,omitempty"`
	// #rrggbb, for a name colour.
	Color string `json:"color,omitempty"`
	// The painted crop, for a frame or a crest. A frame names its pair: the
	// client draws "<art>_square" on cards and "<art>_ring" on the rail.
	Art string `json:"art,omitempty"`
	// Paid when the cosmetic is granted to someone who already owns it, so a
	// duplicate is never worth nothing.
	DupeDiamonds int64 `json:"dupe_diamonds"`
	// Owned by everyone from the start (the crests the game always had).
	DefaultOwned bool `json:"default_owned,omitempty"`
	// Its price in the Splendour shop; zero is not for sale (it comes from its
	// source_hint: a purchase, Royal Favour, an event).
	ShopDiamonds int64 `json:"shop_diamonds,omitempty"`
	// Where it comes from, for the wardrobe's locked rows.
	SourceHint string `json:"source_hint,omitempty"`
}

// Cosmetic returns the cosmetic with this id, or nil.
func (b *Bundle) Cosmetic(id string) *Cosmetic {
	for i := range b.Cosmetics.Items {
		if b.Cosmetics.Items[i].ID == id {
			return &b.Cosmetics.Items[i]
		}
	}
	return nil
}
