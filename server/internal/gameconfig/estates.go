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
	BasePerHourMilli        int64 `json:"base_per_hour_milli"`
	GrowthBP                int64 `json:"growth_bp"`
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
)

func (b *Bundle) Upgrade(id string) *Upgrade { return b.upgradeByID[id] }
func (b *Bundle) Holding(id string) *Holding { return b.holdingByID[id] }
