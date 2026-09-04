package gameconfig

// SoldiersConfig covers recruitment, slot costs, training and the derived
// combat values that turn a roster into a single Might number.
type SoldiersConfig struct {
	MaxSlots              int              `json:"max_slots"`
	Slots                 []SoldierSlot    `json:"slots"`
	RecruitCostPerLevelBP int64            `json:"recruit_cost_per_level_bp"`
	LevelMultPerLevelBP   int64            `json:"level_mult_per_level_bp"`
	Train                 TrainConfig      `json:"train"`
	Onboarding            OnboardingConfig `json:"onboarding"`
	Types                 []SoldierType    `json:"types"`
	Player                PlayerBaseStats  `json:"player"`
	Combat                CombatConfig     `json:"combat"`
}

type SoldierSlot struct {
	Index     int   `json:"index"`
	Cost      int64 `json:"cost"`
	LevelGate int   `json:"level_gate"`
}

type TrainConfig struct {
	Base     int64 `json:"base"`
	GrowthBP int64 `json:"growth_bp"`
}

// OnboardingConfig covers the one-time grants that make the Barracks reachable
// in a first session. Measured need: a fresh account grinds to roughly 322 gold
// at level 5 before energy runs dry, against a 500-gold first slot.
type OnboardingConfig struct {
	FreeSlotAtLevel       int    `json:"free_slot_at_level"`
	FreeFirstRecruit      bool   `json:"free_first_recruit"`
	FirstRecruitTierFloor string `json:"first_recruit_tier_floor"`
}

type SoldierType struct {
	ID       string             `json:"id"`
	Name     string             `json:"name"`
	BaseCost int64              `json:"base_cost"`
	Attack   int64              `json:"attack"`
	Defense  int64              `json:"defense"`
	HP       int64              `json:"hp"`
	Weights  map[string]float64 `json:"weights"`
	LuckCoef float64            `json:"luck_coef"`
}

type PlayerBaseStats struct {
	BaseStat     int64 `json:"base_stat"`
	PerLevel     int64 `json:"per_level"`
	PerStatPoint int64 `json:"per_stat_point"`
	BaseHP       int64 `json:"base_hp"`
	HPPerLevel   int64 `json:"hp_per_level"`
}

type CombatConfig struct {
	HPPerDefenseBP int64 `json:"hp_per_defense_bp"`
	HPLevelBonusBP int64 `json:"hp_level_bonus_bp"`
	DRLevelCoef    int64 `json:"dr_level_coef"`
	DRBase         int64 `json:"dr_base"`
	DRCapBP        int64 `json:"dr_cap_bp"`

	// Battle simulation. FortuneSigmaBP is the primary calibration knob: it is
	// the only parameter that can move the win curve, because a volley battle
	// averages ~200 damage rolls per side and per-hit noise vanishes.
	DMGKBP                int64 `json:"dmg_k_bp"`
	RageStepBP            int64 `json:"rage_step_bp"`
	MaxRounds             int   `json:"max_rounds"`
	VarianceMinBP         int64 `json:"variance_min_bp"`
	VarianceMaxBP         int64 `json:"variance_max_bp"`
	CritMultBP            int64 `json:"crit_mult_bp"`
	CritBaseBP            int64 `json:"crit_base_bp"`
	CritSpeedBP           int64 `json:"crit_speed_bp"`
	CritCapBP             int64 `json:"crit_cap_bp"`
	DodgeSpeedBP          int64 `json:"dodge_speed_bp"`
	DodgeCapBP            int64 `json:"dodge_cap_bp"`
	ChargeBonusBP         int64 `json:"charge_bonus_bp"`
	HomeGroundBP          int64 `json:"home_ground_bp"`
	FortuneSigmaBP        int64 `json:"fortune_sigma_bp"`
	FortuneClampSigmasX10 int64 `json:"fortune_clamp_sigmas_x10"`
}

// SoldierType returns the type with this id, or nil.
func (b *Bundle) SoldierType(id string) *SoldierType { return b.soldierTypeByID[id] }

// SlotCost returns the price of the nth slot (1-based) and its level gate.
// ok is false when n is past the cap.
func (b *Bundle) SlotCost(n int) (cost int64, levelGate int, ok bool) {
	for _, s := range b.Soldiers.Slots {
		if s.Index == n {
			return s.Cost, s.LevelGate, true
		}
	}
	return 0, 0, false
}
