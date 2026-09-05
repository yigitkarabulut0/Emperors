package gameconfig

// ItemsConfig holds everything about gear. All multipliers are integer basis
// points so stat maths never touches a float and every implementation — server,
// admin simulator, client display — produces the identical number.
type ItemsConfig struct {
	TierMultBP         map[string]int64     `json:"tier_mult_bp"`
	TierPriceMultBP    map[string]int64     `json:"tier_price_mult_bp"`
	SlotBase           map[string]SlotStats `json:"slot_base"`
	LevelMultPerIlvlBP int64                `json:"level_mult_per_ilvl_bp"`
	Quality            QualityRange         `json:"quality"`
	Masterwork         MasterworkConfig     `json:"masterwork"`
	Price              PriceConfig          `json:"price"`
	SpeedPowerWeightBP int64                `json:"speed_power_weight_bp"`
	Shop               ShopConfig           `json:"shop"`
	Definitions        []ItemDef            `json:"definitions"`
}

type SlotStats struct {
	Attack  int64 `json:"attack"`
	Defense int64 `json:"defense"`
	Speed   int64 `json:"speed"`
}

type QualityRange struct {
	MinPct int64 `json:"min_pct"`
	MaxPct int64 `json:"max_pct"`
}

type MasterworkConfig struct {
	ChanceBP int64 `json:"chance_bp"`
	MultPct  int64 `json:"mult_pct"`
}

type PriceConfig struct {
	Coef        float64 `json:"coef"`
	Exponent    float64 `json:"exponent"`
	SellRatioBP int64   `json:"sell_ratio_bp"`
}

type ShopConfig struct {
	Slots              int                `json:"slots"`
	WindowSeconds      int64              `json:"window_seconds"`
	BaseWeights        map[string]float64 `json:"base_weights"`
	LuckCoef           float64            `json:"luck_coef"`
	RerollBaseDiamonds int64              `json:"reroll_base_diamonds"`
	RerollStepDiamonds int64              `json:"reroll_step_diamonds"`
}

type ItemDef struct {
	ID   string `json:"id"`
	Slot string `json:"slot"`
	Tier string `json:"tier"`
	Name string `json:"name"`
	Art  string `json:"art"`
}

// Slot names. A horse cannot go in a weapon slot, and the type system should say
// so rather than a comment.
const (
	SlotWeapon = "weapon"
	SlotArmor  = "armor"
	SlotHorse  = "horse"
)

// ValidSlot reports whether s names a real equipment slot.
func ValidSlot(s string) bool {
	return s == SlotWeapon || s == SlotArmor || s == SlotHorse
}

// ItemDef returns the definition with this id, or nil.
func (b *Bundle) ItemDef(id string) *ItemDef { return b.itemByID[id] }

// ItemDefsFor returns every definition for a (slot, tier) pair.
func (b *Bundle) ItemDefsFor(slot, tier string) []*ItemDef {
	return b.itemsBySlotTier[slot+"/"+tier]
}

// TierRank returns a tier's 1-based position, or 0 when unknown.
func (b *Bundle) TierRank(id string) int {
	if t, ok := b.tierByID[id]; ok {
		return t.Rank
	}
	return 0
}

// TierIDsAscending lists tier ids weakest first. Roll weights are indexed by
// this order, so it must stay stable.
func (b *Bundle) TierIDsAscending() []string { return b.tierIDs }
