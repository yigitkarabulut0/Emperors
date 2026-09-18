package gameconfig

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
)

// Boostable buckets a reward may carry a timed bonus in. Energy regeneration is
// never one: a timed regen boost is a mint (see economy.Caps).
var rewardBoostBuckets = map[string]bool{BucketCollectIncome: true, BucketXP: true, BucketLuck: true}

// validateRewards checks the reward machinery's own data.
func (b *Bundle) validateRewards() []string {
	var p []string
	r := b.Rewards

	if len(r.Tokens) == 0 {
		p = append(p, "rewards.tokens is empty — the rewards section is missing or was not generated")
	}
	seen := map[string]bool{}
	for _, t := range r.Tokens {
		if t.ID == "" || t.Name == "" || t.Icon == "" {
			p = append(p, fmt.Sprintf("rewards.tokens: %q needs an id, a name and an icon", t.ID))
		}
		if seen[t.ID] {
			p = append(p, fmt.Sprintf("rewards.tokens: %q is defined twice", t.ID))
		}
		seen[t.ID] = true
		if t.EnergyPct < 0 || t.EnergyPct > 100 {
			p = append(p, fmt.Sprintf("rewards.tokens: %q restores %d%% of the pool — it must be 0 to 100", t.ID, t.EnergyPct))
		}
		if t.EnergyPct > 0 && t.PaidOK {
			p = append(p, fmt.Sprintf("rewards.tokens: %q restores energy and money may carry it — bought energy is the day's refills and nothing more", t.ID))
		}
	}

	m := r.Mail
	if m.DefaultExpiryDays <= 0 || m.PurgeAfterDays <= 0 || m.InboxLimit <= 0 || m.ClaimAllMax <= 0 {
		p = append(p, "rewards.mail: every field must be positive — zero would expire letters at once or show none")
	}

	l := r.Limits
	if l.MaxDiamonds <= 0 || l.MaxGold <= 0 || l.MaxXP <= 0 || l.MaxWages <= 0 || l.MaxFavour <= 0 ||
		l.MaxItems <= 0 || l.MaxTokens <= 0 || l.MaxBoostHours <= 0 {
		p = append(p, "rewards.limits: every limit must be positive — zero would refuse every reward")
	}

	pr := r.Promo
	if pr.MaxDiamonds <= 0 || pr.FailuresPerHour <= 0 || pr.ExpiryDays <= 0 {
		p = append(p, "rewards.promo: max_diamonds, failures_per_hour and expiry_days must be positive")
	}
	rf := r.Referral
	if rf.RewardLevel < 2 || rf.InviteeDiamonds <= 0 || rf.InviterDiamonds <= 0 || rf.ClaimDays <= 0 ||
		rf.InviterMinHours < 0 || rf.LinksPerDay <= 0 || rf.RewardsTotal <= 0 {
		p = append(p, "rewards.referral: every field must be positive, and the reward level above 1")
	}
	if rf.RewardLevel > b.Progression.LevelCap {
		p = append(p, fmt.Sprintf("rewards.referral: reward_level %d is past the level cap", rf.RewardLevel))
	}

	p = append(p, b.validateCosmetics()...)

	if b.Items.Shop.RerollsPerDay <= 0 {
		p = append(p, "items.shop.rerolls_per_day must be positive — zero would refuse every reroll, and no cap is how a purse buys gear")
	}
	if b.Items.InventoryCap <= 0 {
		p = append(p, "items.inventory_cap must be positive — zero would refuse every item")
	}
	return p
}

var hexColor = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

// The two grounds a name is drawn on: the card plate and the navy page. A name
// colour must read on both.
var cosmeticGrounds = []string{"#1B1712", "#0B151F"}

func (b *Bundle) validateCosmetics() []string {
	var p []string
	if len(b.Cosmetics.Items) == 0 {
		p = append(p, "cosmetics.items is empty — the cosmetics section is missing or was not generated")
	}
	seen := map[string]bool{}
	for _, c := range b.Cosmetics.Items {
		if c.ID == "" || c.Name == "" {
			p = append(p, fmt.Sprintf("cosmetics: %q needs an id and a name", c.ID))
		}
		if seen[c.ID] {
			p = append(p, fmt.Sprintf("cosmetics: %q is defined twice", c.ID))
		}
		seen[c.ID] = true
		switch c.Kind {
		case CosmeticFrame, CosmeticCrest:
			if c.Art == "" {
				p = append(p, fmt.Sprintf("cosmetics: %s %q has no art", c.Kind, c.ID))
			}
		case CosmeticTitle:
			if c.Text == "" || len([]rune(c.Text)) > 24 {
				p = append(p, fmt.Sprintf("cosmetics: title %q needs text of 1 to 24 characters", c.ID))
			}
		case CosmeticNameColor:
			if !hexColor.MatchString(c.Color) {
				p = append(p, fmt.Sprintf("cosmetics: name colour %q is not #rrggbb", c.ID))
				break
			}
			for _, g := range cosmeticGrounds {
				if ratio := contrast(c.Color, g); ratio < 4.5 {
					p = append(p, fmt.Sprintf("cosmetics: name colour %q reads at %.2f:1 on %s — a name must reach 4.5:1",
						c.ID, ratio, g))
				}
			}
		default:
			p = append(p, fmt.Sprintf("cosmetics: %q has unknown kind %q", c.ID, c.Kind))
		}
		if !c.DefaultOwned && c.DupeDiamonds <= 0 {
			p = append(p, fmt.Sprintf("cosmetics: %q must pay dupe_diamonds when granted twice — a duplicate worth nothing is a reward that says nothing", c.ID))
		}
	}
	return p
}

// contrast is the WCAG contrast ratio between two #rrggbb colours. Validation
// only: nothing in the economy is a float.
func contrast(a, b string) float64 {
	la, lb := luminance(a), luminance(b)
	if la < lb {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05)
}

func luminance(hex string) float64 {
	ch := func(i int) float64 {
		v, _ := strconv.ParseUint(hex[i:i+2], 16, 8)
		c := float64(v) / 255
		if c <= 0.03928 {
			return c / 12.92
		}
		return math.Pow((c+0.055)/1.055, 2.4)
	}
	return 0.2126*ch(1) + 0.7152*ch(3) + 0.0722*ch(5)
}

// CheckReward is every reason a reward bundle could not be delivered, empty when
// it can. paid marks a bundle money buys: it may carry no gold, experience,
// favour, items or timed bonus, and no token that is not paid_ok (FAIR: money
// buys time, comfort and looks, never gold or power, and never a loot box).
// MaxBoostGrantBP is the most any one timed bonus may carry, granted or
// accumulated: +200%, which is the timed collect lane's own cap
// (economy.Caps). One place, because the kingdom's aid stack is measured
// against it too -- a stack that alone reached the lane's ceiling would make
// every other timed bonus in the game worth nothing while it ran.
const MaxBoostGrantBP int64 = 20000

func (b *Bundle) CheckReward(r RewardBundle, paid bool) []string {
	var p []string
	l := b.Rewards.Limits
	within := func(name string, v, max int64) {
		if v < 0 {
			p = append(p, fmt.Sprintf("%s is negative", name))
		}
		if v > max {
			p = append(p, fmt.Sprintf("%s %d is over the limit %d", name, v, max))
		}
	}
	within("diamonds", r.Diamonds, l.MaxDiamonds)
	within("gold", r.Gold, l.MaxGold)
	within("xp", r.XP, l.MaxXP)
	within("gold_wages", r.GoldWages, l.MaxWages)
	within("xp_wages", r.XPWages, l.MaxWages)
	within("favour", r.Favour, l.MaxFavour)

	for id, n := range r.Tokens {
		t := b.Token(id)
		if t == nil {
			p = append(p, fmt.Sprintf("unknown token %q", id))
			continue
		}
		if n <= 0 || n > l.MaxTokens {
			p = append(p, fmt.Sprintf("token %q count %d is outside 1..%d", id, n, l.MaxTokens))
		}
		if paid && !t.PaidOK {
			p = append(p, fmt.Sprintf("token %q may not be sold", id))
		}
	}

	items := 0
	for _, it := range r.Items {
		if it.Count <= 0 {
			p = append(p, "an item grant has no count")
		}
		items += it.Count
		if b.tierByID[it.Tier] == nil {
			p = append(p, fmt.Sprintf("item grant: unknown tier %q", it.Tier))
		}
		if it.Slot != "" && it.Slot != "weapon" && it.Slot != "armor" && it.Slot != "horse" {
			p = append(p, fmt.Sprintf("item grant: unknown slot %q", it.Slot))
		}
	}
	if items > l.MaxItems {
		p = append(p, fmt.Sprintf("%d items is over the limit %d", items, l.MaxItems))
	}

	for _, id := range r.Cosmetics {
		c := b.Cosmetic(id)
		switch {
		case c == nil:
			p = append(p, fmt.Sprintf("unknown cosmetic %q", id))
		case c.DefaultOwned:
			p = append(p, fmt.Sprintf("cosmetic %q is owned by everyone already", id))
		}
	}

	for _, bg := range r.Boosts {
		if !rewardBoostBuckets[bg.Bucket] {
			p = append(p, fmt.Sprintf("boost bucket %q cannot be granted", bg.Bucket))
		}
		if bg.BP <= 0 || bg.BP > MaxBoostGrantBP {
			p = append(p, fmt.Sprintf("boost of %d bp is outside 1..%d", bg.BP, MaxBoostGrantBP))
		}
		if bg.Hours <= 0 || bg.Hours > l.MaxBoostHours {
			p = append(p, fmt.Sprintf("boost of %d hours is outside 1..%d", bg.Hours, l.MaxBoostHours))
		}
	}

	if paid {
		if r.Gold != 0 || r.GoldWages != 0 {
			p = append(p, "a paid reward may not carry gold")
		}
		if r.XP != 0 || r.XPWages != 0 {
			p = append(p, "a paid reward may not carry experience")
		}
		if r.Favour != 0 {
			p = append(p, "a paid reward may not carry favour")
		}
		if len(r.Items) > 0 {
			p = append(p, "a paid reward may not carry gear")
		}
		if len(r.Boosts) > 0 {
			p = append(p, "a paid reward may not carry a timed bonus")
		}
	}
	return p
}
