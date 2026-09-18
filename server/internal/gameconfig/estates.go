package gameconfig

// EstatesConfig covers the Family upgrade tree and Territory holdings.
type EstatesConfig struct {
	Upgrades []Upgrade `json:"upgrades"`
	Holdings []Holding `json:"holdings"`
	Tax      TaxConfig `json:"tax"`
}

// Upgrade is one node of the Family tree. Effects are additive within their
// bucket, and the bucket applies once — there is no compounding between nodes.
type Upgrade struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Bucket   string  `json:"bucket"`
	MaxLevel int     `json:"max_level"`
	PerLevel int64   `json:"per_level"`
	Blurb    string  `json:"blurb"`
	Costs    []int64 `json:"costs"`
}

// Cost returns the price of advancing from level to level+1.
func (u Upgrade) Cost(level int) (int64, bool) {
	if level < 0 || level >= len(u.Costs) {
		return 0, false
	}
	return u.Costs[level], true
}

// Holding is one Territory estate: the passive income engine.
type Holding struct {
	ID                      string  `json:"id"`
	Name                    string  `json:"name"`
	UnlockLevel             int     `json:"unlock_level"`
	MaxLevel                int     `json:"max_level"`
	TaxMilliPerHourPerLevel int64   `json:"tax_milli_per_hour_per_level"`
	Costs                   []int64 `json:"costs"`
}

func (h Holding) Cost(level int) (int64, bool) {
	if level < 0 || level >= len(h.Costs) {
		return 0, false
	}
	return h.Costs[level], true
}

type TaxConfig struct {
	BasePerHourMilli int64 `json:"base_per_hour_milli"`
	GrowthBP         int64 `json:"growth_bp"`

	// The storehouse's size (service/storehouse.go): this many seconds of the
	// hourly rate, and this many more for each Tithe Barn level. Income past it
	// is lost until the lord carries the storehouse in.
	OfflineCapSeconds       int64 `json:"offline_cap_seconds"`
	OfflineCapPerTitheLevel int64 `json:"offline_cap_per_tithe_level"`
}

// Bucket names used by upgrades. Anything not a basis-point bucket is applied
// directly by the service that owns it.
const (
	BucketCollectIncome = "collect_income_bp"
	BucketTaxIncome     = "tax_income_bp"
	BucketXP            = "xp_bp"
	BucketEnergyRegen   = "energy_regen_bp"
	BucketMaxEnergyFlat = "max_energy_flat"
	BucketSoldierAtk    = "soldier_atk_bp"
	BucketSoldierDef    = "soldier_def_bp"
	BucketSoldierSpd    = "soldier_spd_bp"
	BucketShopDiscount  = "shop_discount_bp"
	BucketStealCap      = "steal_cap_bp"
	BucketRansom        = "ransom_bp"
	BucketLuck          = "luck_bp"
	// The storehouse's own window, in MINUTES rather than basis points: it is a
	// length of time and not a share of an amount. The Tithe Barn lengthens it
	// through its own field; a talent lengthens it through this name.
	BucketStorehouseMinutes = "storehouse_minutes"
)

func (b *Bundle) Upgrade(id string) *Upgrade { return b.upgradeByID[id] }
func (b *Bundle) Holding(id string) *Holding { return b.holdingByID[id] }

// MaxTaxIncomeBP is the ceiling on the tax_income_bp bucket, in basis points.
//
// Every other percentage bucket is capped inside economy.ApplyBucket, but tax is
// not an amount scaled at a call site -- it is a stored hourly RATE, so it never
// passes through that function and for a long time had no ceiling at all. That
// was not theoretical: a Tithe Barn at +100% stacked with a kingdom's Royal
// Treasury at +40% multiplied every estate by 2.4, putting a mid-level player's
// passive income at three times what playing earned them.
//
// The reachable sum is +40%. This leaves headroom for future content while
// bounding the runaway. Validate rejects a config that could exceed it, and
// estates.TaxRate clamps to it at read time.
//
// It lives here for the same reason MaxLuckBP does: Validate has to reject an
// over-cap config at PUBLISH time, and gameconfig cannot import the estates
// package -- estates imports gameconfig.
const MaxTaxIncomeBP int64 = 6000

// MaxLuckBP is the ceiling on a luck bonus, in basis points on the tier ladder's
// LEVEL coefficient. +10000 doubles that coefficient.
//
// It lives here rather than next to the item helpers because Validate has to
// reject an over-cap config node at PUBLISH time, and gameconfig cannot import
// items -- items imports gameconfig. It is no less unavoidable for that: both
// places luck is consumed go through items.ClampLuckBP.
//
// Doubling the coefficient is strictly less than doubling a player's effective
// level in the ladder, so luck can never produce a tier distribution the game
// does not already hand its own high-level players.
const MaxLuckBP = 10000
