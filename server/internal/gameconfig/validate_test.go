package gameconfig

import (
	"strings"
	"testing"
)

// The two checks added when the level curve was rebalanced.
//
// A validator that cannot be made to fire is worse than none, because it reads
// as cover. Both of these reproduce the exact configuration that shipped.

func TestValidateRejectsAFlatXPLadder(t *testing.T) {
	b, _ := LoadSeed()
	// The formula that actually shipped: xp/energy rising 2.00 -> 2.60 across the
	// whole ladder, while the experience a level costs rises about 400x.
	for i := range b.Jobs.Jobs {
		j := &b.Jobs.Jobs[i]
		j.BaseXP = int64(float64(j.EnergyCost) * (1.40 + 0.02*float64(j.UnlockLevel)))
		if j.BaseXP < 2 {
			j.BaseXP = 2
		}
	}
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a ladder whose xp/energy rises 1.3x")
	}
	if !strings.Contains(err.Error(), "xp/energy only rises") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsAPoolSmallerThanAnHourOfRegen(t *testing.T) {
	b, _ := LoadSeed()
	// Halving the regen period without growing the pool: the change that looks
	// like a buff and is worth nothing to anyone who checks in hourly.
	b.Progression.Energy.BaseMax = 60
	b.Progression.Energy.RegenBaseSeconds = 30
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a 60-point pool at two energy a minute")
	}
	if !strings.Contains(err.Error(), "less than one hour of regen") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// The store's prices are the one place a forgotten generator run turns into a
// free purchase rather than a refused load.
func TestValidateRejectsAFreeRename(t *testing.T) {
	b, _ := LoadSeed()
	b.Progression.Store.RenameDiamonds = 0
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a rename that costs nothing")
	}
	if !strings.Contains(err.Error(), "rename_diamonds") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// The two joining settings read as zero when the generator gained them and was
// not re-run -- the same failure that once shipped an action for one gold.
// Zero is not a setting for either: no cooldown makes a kingdom a raid shield,
// and a request cap of zero refuses every request.
func TestValidateRejectsMissingJoinSettings(t *testing.T) {
	for _, c := range []struct {
		field string
		zero  func(b *Bundle)
	}{
		{"rejoin_cooldown_minutes", func(b *Bundle) { b.Kingdoms.RejoinCooldownMinutes = 0 }},
		{"max_join_requests", func(b *Bundle) { b.Kingdoms.MaxJoinRequests = 0 }},
	} {
		b, _ := LoadSeed()
		c.zero(b)
		if err := b.build(); err != nil {
			t.Fatal(err)
		}
		err := b.Validate()
		if err == nil {
			t.Fatalf("Validate accepted a zero %s", c.field)
		}
		if !strings.Contains(err.Error(), c.field) {
			t.Errorf("%s: rejected for the wrong reason: %v", c.field, err)
		}
	}
}

// A reroll costs the recruit price less the dismiss refund, and both come off
// base_cost and sell_ratio_bp. Each of these would price it at nothing or roll
// it from an empty table.
func TestValidateRejectsAFreeOrEmptyRecruit(t *testing.T) {
	for _, c := range []struct {
		name   string
		break_ func(b *Bundle)
		want   string
	}{
		{"free soldier", func(b *Bundle) { b.Soldiers.Types[0].BaseCost = 0 }, "base_cost must be positive"},
		{"empty weights", func(b *Bundle) {
			for k := range b.Soldiers.Types[1].Weights {
				b.Soldiers.Types[1].Weights[k] = 0
			}
		}, "tier weights sum to nothing"},
		{"full refund", func(b *Bundle) { b.Items.Price.SellRatioBP = 10000 }, "reroll would cost nothing"},
		{"no reroll cap", func(b *Bundle) { b.Items.Shop.RerollsPerDay = 0 }, "rerolls_per_day must be positive"},
	} {
		b, _ := LoadSeed()
		c.break_(b)
		if err := b.build(); err != nil {
			t.Fatal(err)
		}
		err := b.Validate()
		if err == nil {
			t.Fatalf("%s: Validate accepted it", c.name)
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: rejected for the wrong reason: %v", c.name, err)
		}
	}
}

// The refill ladder is the daily limit on bought energy, so every way it can be
// wrong must refuse to load: missing (the old document, read as nothing), a free
// step, or a step cheaper than the one before it.
func TestValidateRejectsABrokenRefillLadder(t *testing.T) {
	cases := []struct {
		name   string
		prices []int64
		reason string
	}{
		{"missing", nil, "must hold 1 to 6 prices"},
		{"too long", []int64{1, 2, 3, 4, 5, 6, 7}, "must hold 1 to 6 prices"},
		{"a free refill", []int64{20, 0, 45}, "must be positive"},
		{"falling", []int64{20, 45, 30}, "must not fall"},
	}
	for _, c := range cases {
		b, _ := LoadSeed()
		b.Progression.Store.EnergyRefillPrices = c.prices
		if err := b.build(); err != nil {
			t.Fatal(err)
		}
		err := b.Validate()
		if err == nil {
			t.Errorf("%s: Validate accepted energy_refill_prices %v", c.name, c.prices)
			continue
		}
		if !strings.Contains(err.Error(), c.reason) {
			t.Errorf("%s: rejected for the wrong reason: %v", c.name, err)
		}
	}
}

// The seed sells three refills a day at a rising price.
func TestTheSeedRefillLadder(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	got := b.Progression.Store.EnergyRefillPrices
	if len(got) != 3 || got[0] != 20 || got[1] != 30 || got[2] != 45 {
		t.Fatalf("seed refill ladder %v, want [20 30 45]", got)
	}
}

// Money buys time, comfort and looks: a paid reward carrying gold, experience,
// favour, gear or a timed bonus is refused, as is any token not marked paid_ok.
func TestAPaidRewardCannotCarryGoldOrPower(t *testing.T) {
	b, _ := LoadSeed()
	for name, r := range map[string]RewardBundle{
		"gold":   {Diamonds: 100, Gold: 5000},
		"wages":  {Diamonds: 100, GoldWages: 60},
		"xp":     {XP: 500},
		"favour": {Favour: 40},
		"gear":   {Items: []ItemGrant{{Tier: "legendary", Count: 1}}},
		"boost":  {Boosts: []BoostGrant{{Bucket: BucketCollectIncome, BP: 5000, Hours: 24}}},
	} {
		if len(b.CheckReward(r, true)) == 0 {
			t.Errorf("a paid reward carrying %s was accepted", name)
		}
		if len(b.CheckReward(r, false)) != 0 {
			t.Errorf("the same %s reward, earned, was refused: %v", name, b.CheckReward(r, false))
		}
	}
	if p := b.CheckReward(RewardBundle{Diamonds: 700, Tokens: map[string]int64{"energy_potion": 3}}, true); len(p) != 0 {
		t.Fatalf("diamonds and potions for money were refused: %v", p)
	}
}

// A token the balance does not define, a tier that does not exist, a number
// past its limit: refused, never delivered.
func TestARewardOutsideTheRulesIsRefused(t *testing.T) {
	b, _ := LoadSeed()
	for name, r := range map[string]RewardBundle{
		"unknown token":     {Tokens: map[string]int64{"dragon_egg": 1}},
		"unknown tier":      {Items: []ItemGrant{{Tier: "godly", Count: 1}}},
		"too many diamonds": {Diamonds: b.Rewards.Limits.MaxDiamonds + 1},
		"negative gold":     {Gold: -5},
		"regen boost":       {Boosts: []BoostGrant{{Bucket: "energy_regen_bp", BP: 1000, Hours: 1}}},
		"default crest":     {Cosmetics: []string{"crest_lion"}},
		"unknown cosmetic":  {Cosmetics: []string{"frame_of_nothing"}},
	} {
		if len(b.CheckReward(r, false)) == 0 {
			t.Errorf("%s: accepted", name)
		}
	}
}

// A name colour must read on both grounds a name is drawn on.
func TestANameColourMustRead(t *testing.T) {
	b, _ := LoadSeed()
	b.Cosmetics.Items = append(b.Cosmetics.Items, Cosmetic{
		ID: "color_mud", Kind: CosmeticNameColor, Name: "Mud", Color: "#3A2E22", DupeDiamonds: 5,
	})
	err := b.Validate()
	if err == nil || !strings.Contains(err.Error(), "a name must reach 4.5:1") {
		t.Fatalf("a dark brown name colour was accepted: %v", err)
	}
	b, _ = LoadSeed()
	b.Cosmetics.Items = append(b.Cosmetics.Items, Cosmetic{
		ID: "color_gold", Kind: CosmeticNameColor, Name: "Burnished Gold", Color: "#E8C66A", DupeDiamonds: 5,
	})
	if err := b.Validate(); err != nil {
		t.Fatalf("a gold that reads on both grounds was refused: %v", err)
	}
}

// The document without the new sections -- what the database held before them --
// must refuse to load rather than run with zero limits and no tokens.
func TestAMissingRewardsSectionIsRefused(t *testing.T) {
	b, _ := LoadSeed()
	b.Rewards = RewardsConfig{}
	b.Cosmetics = CosmeticsConfig{}
	err := b.Validate()
	if err == nil || !strings.Contains(err.Error(), "rewards.tokens is empty") ||
		!strings.Contains(err.Error(), "cosmetics.items is empty") {
		t.Fatalf("a document with no rewards or cosmetics section loaded: %v", err)
	}
}

// The readable numbers beside the real ones.
//
// `stat_mult` drifted a whole curve from `tier_mult_bp` and nothing noticed,
// because nothing reads stat_mult. The check written after that only covered
// stat_mult; `pips` and `cumulative_xp` are the same kind of number -- readable,
// derived, and read by nothing at all -- and sat unguarded beside it for a year.
// These two hold them now, and the tests exist because a validator nobody can
// make fire reads as cover.

func TestValidateRejectsPipsThatDisagreeWithTheRank(t *testing.T) {
	b, _ := LoadSeed()
	// A tier that wears five pips at rank three: the drift a hand edit makes.
	for i := range b.Tiers.Tiers {
		if b.Tiers.Tiers[i].Rank == 3 {
			b.Tiers.Tiers[i].Pips = 5
		}
	}
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a tier wearing more pips than its rank")
	}
	if !strings.Contains(err.Error(), "pips 5 disagrees with rank 3") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

func TestValidateRejectsACumulativeXPThatDisagreesWithTheCurve(t *testing.T) {
	b, _ := LoadSeed()
	if len(b.Progression.Levels) < 3 {
		t.Skip("this seed has no ladder to drift")
	}
	// The shape of the real failure: the curve is rebalanced and the running
	// total beside it is not regenerated, so the document reads as though a
	// level costs what it no longer costs.
	b.Progression.Levels[2].CumulativeXP += 1000
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	err := b.Validate()
	if err == nil {
		t.Fatal("Validate accepted a running total that disagrees with the curve it totals")
	}
	if !strings.Contains(err.Error(), "cumulative_xp") {
		t.Errorf("rejected for the wrong reason: %v", err)
	}
}

// And the shipped document passes both, which is the other half of the claim.
func TestTheShippedLadderAndTiersAgreeWithThemselves(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	if err := b.build(); err != nil {
		t.Fatal(err)
	}
	if err := b.Validate(); err != nil {
		t.Fatalf("the shipped document does not pass its own checks: %v", err)
	}
	var run int64
	for _, l := range b.Progression.Levels {
		if l.CumulativeXP != run {
			t.Fatalf("level %d: cumulative_xp %d, the curve totals %d", l.Level, l.CumulativeXP, run)
		}
		run += l.XPToNext
	}
	for _, tier := range b.Tiers.Tiers {
		if tier.Pips != tier.Rank {
			t.Errorf("tier %q: %d pips at rank %d", tier.ID, tier.Pips, tier.Rank)
		}
	}
}
