// Package rewards is the pure half of paying a player: what a reward bundle is
// worth to THIS player, which gear it rolls, and the lines that say so.
//
// Pure like the rest of internal/game. The service writes what this computes;
// nothing here knows about a database or the clock.
package rewards

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/items"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Resolved is a bundle's gold and experience for one player: its flat amounts
// plus its wages, worked out at that player's level.
type Resolved struct {
	Gold int64
	// Experience before the XP bucket; AwardXP applies the bucket as it credits.
	XP int64
}

// Resolve works out the level-dependent part of a bundle.
//
// Wages are paid in energy: what that much energy earns at the best job the
// player can do. Gold goes through the collect bucket's PERMANENT lane only --
// a letter opened during "Gold Rush" is worth what it is worth at any other
// hour, so nobody has to time their claims.
func Resolve(cfg *gameconfig.Bundle, b gameconfig.RewardBundle, level int, bonuses economy.Bonuses) Resolved {
	r := Resolved{Gold: b.Gold, XP: b.XP}
	if b.GoldWages <= 0 && b.XPWages <= 0 {
		return r
	}
	job := BestJob(cfg, level)
	if job == nil {
		return r
	}
	if b.GoldWages > 0 {
		base := job.BaseGold * b.GoldWages / job.EnergyCost
		r.Gold += economy.ApplyBucket(base, PermanentOnly(bonuses), economy.BucketCollectIncome)
	}
	if b.XPWages > 0 {
		r.XP += job.BaseXP * b.XPWages / job.EnergyCost
	}
	return r
}

// PermanentOnly is a player's bonuses with every timed lane emptied: what a
// reward is worth at any hour, not just while an event runs.
func PermanentOnly(b economy.Bonuses) economy.Bonuses {
	for _, perm := range []economy.Bucket{economy.BucketCollectIncome, economy.BucketXPGain} {
		if lane, ok := economy.TempLane(perm); ok {
			b[lane] = 0
		}
	}
	return b
}

// BestJob is the job with the best gold per energy the player can do at this
// level: the last rung they have unlocked.
func BestJob(cfg *gameconfig.Bundle, level int) *gameconfig.Job {
	jobs := cfg.JobsForLevel(level)
	if len(jobs) == 0 {
		return nil
	}
	best := jobs[0]
	for _, j := range jobs[1:] {
		if j.BaseGold*best.EnergyCost > best.BaseGold*j.EnergyCost {
			best = j
		}
	}
	return best
}

// Items rolls the gear a bundle grants, at the player's own level.
//
// Seeded from the grant's reference (a letter's id, a transaction's), so a retry
// of the same grant rolls the same gear and cannot be used to reroll it.
func Items(cfg *gameconfig.Bundle, secret []byte, ref string, level, luckBP int64,
	grants []gameconfig.ItemGrant) []items.Instance {
	var out []items.Instance
	n := 0
	for _, g := range grants {
		for c := 0; c < g.Count; c++ {
			rng := game.SeedForString(secret, "reward:"+ref, uint64(n))
			n++
			slot := g.Slot
			if slot == "" {
				slot = []string{"weapon", "armor", "horse"}[rng.IntN(3)]
			}
			if it := items.Roll(cfg, rng, slot, g.Tier, level, luckBP); it.DefID != "" {
				out = append(out, it)
			}
		}
	}
	return out
}

// ItemCount is how many pieces of gear a bundle grants.
func ItemCount(b gameconfig.RewardBundle) int64 {
	var n int64
	for _, g := range b.Items {
		n += int64(g.Count)
	}
	return n
}

// Line is one row of "what this reward gives", with its words already written.
// The client draws Icon and Text and computes nothing.
type Line struct {
	Kind   string `json:"kind"`
	ID     string `json:"id,omitempty"`
	Amount int64  `json:"amount"`
	Text   string `json:"text"`
	// A semantic art key ("diamond", "gold", "xp", "favour", a token's icon,
	// "item:rare", "boost:collect", "boost:xp") that the client maps to a
	// painted crop -- or, for a cosmetic with art in its catalogue, that crop
	// itself ("icons/crest_lion"). A key with a slash is a crop; the client
	// keeps no catalogue of its own.
	Icon string `json:"icon"`
	// #rrggbb, for a name colour: the client tints its enamel chip with it.
	Color string `json:"color,omitempty"`
	// A piece of gear's tier id ("rare"), so the client lays it on its rarity's
	// cloth, as every other tile of gear is drawn.
	Tier string `json:"tier,omitempty"`
}

// CosmeticKindWord is a cosmetic kind as the game writes it: "name colour",
// in the game's own spelling, not the catalogue key's.
func CosmeticKindWord(kind string) string {
	if kind == "name_color" {
		return "name colour"
	}
	return strings.ReplaceAll(kind, "_", " ")
}

// Lines describes a bundle for one player, with its level-dependent amounts
// already resolved.
func Lines(cfg *gameconfig.Bundle, b gameconfig.RewardBundle, res Resolved) []Line {
	var out []Line
	if b.Diamonds > 0 {
		out = append(out, Line{Kind: "diamonds", Amount: b.Diamonds,
			Text: count(b.Diamonds, "diamond", "diamonds"), Icon: "diamond"})
	}
	if res.Gold > 0 {
		out = append(out, Line{Kind: "gold", Amount: res.Gold, Text: Group(res.Gold) + " gold", Icon: "gold"})
	}
	if res.XP > 0 {
		out = append(out, Line{Kind: "xp", Amount: res.XP, Text: Group(res.XP) + " experience", Icon: "xp"})
	}
	if b.Favour > 0 {
		out = append(out, Line{Kind: "favour", Amount: b.Favour, Text: Group(b.Favour) + " favour", Icon: "favour"})
	}
	for _, id := range sortedKeys(b.Tokens) {
		n := b.Tokens[id]
		name, icon := id, id
		if t := cfg.Token(id); t != nil {
			name, icon = t.Name, t.Icon
		}
		text := name
		if n > 1 {
			text = fmt.Sprintf("%d %ss", n, name)
		}
		out = append(out, Line{Kind: "token", ID: id, Amount: n, Text: text, Icon: icon})
	}
	for _, g := range b.Items {
		tier := g.Tier
		if t := cfg.Tier(g.Tier); t != nil {
			tier = t.Name
		}
		what := "gear"
		if g.Slot != "" {
			what = g.Slot
		}
		text := fmt.Sprintf("%s %s", tier, what)
		if g.Count > 1 {
			text = fmt.Sprintf("%d × %s %s", g.Count, tier, what)
		}
		out = append(out, Line{Kind: "item", ID: g.Tier, Amount: int64(g.Count), Text: text, Icon: "item:" + g.Tier, Tier: g.Tier})
	}
	for _, id := range b.Cosmetics {
		name, kind, icon, color := id, "cosmetic", "cosmetic:"+id, ""
		if c := cfg.Cosmetic(id); c != nil {
			name, kind, icon, color = c.Name, c.Kind, c.Kind+":"+id, c.Color
			if c.Art != "" {
				icon = c.Art
			}
		}
		out = append(out, Line{Kind: "cosmetic", ID: id, Amount: 1,
			Text: fmt.Sprintf("%s (%s)", name, CosmeticKindWord(kind)), Icon: icon, Color: color})
	}
	for _, bg := range b.Boosts {
		what := "gold"
		icon := "boost:collect"
		switch bg.Bucket {
		case gameconfig.BucketXP:
			what, icon = "experience", "boost:xp"
		case gameconfig.BucketLuck:
			what, icon = "luck", "boost:luck"
		}
		span := fmt.Sprintf("%d hours", bg.Hours)
		if bg.Hours == 1 {
			span = "an hour"
		}
		out = append(out, Line{Kind: "boost", ID: bg.Bucket, Amount: bg.BP,
			Text: fmt.Sprintf("+%d%% %s for %s", bg.BP/100, what, span), Icon: icon})
	}
	return out
}

func count(n int64, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return Group(n) + " " + many
}

// Group writes a number with thousands separators: 12,345.
func Group(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

func sortedKeys(m map[string]int64) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// RolledLines names the gear a grant actually rolled: each generic "item" line
// ("Rare weapon") gives way to one line per item, with its name and its own
// painted design as the icon (items/painted/<art>, a crop the client draws as
// it is). Before the roll -- a letter still sealed, a store preview -- there is
// no item yet, and the generic line with its rarity stays. Every other line is
// kept, in its place.
func RolledLines(cfg *gameconfig.Bundle, lines []Line, rolled []items.Instance) []Line {
	if len(rolled) == 0 {
		return lines
	}
	out := make([]Line, 0, len(lines)+len(rolled))
	placed := false
	for _, l := range lines {
		if l.Kind != "item" {
			out = append(out, l)
			continue
		}
		if placed {
			continue
		}
		placed = true
		for _, it := range rolled {
			tier := it.Tier
			if t := cfg.Tier(it.Tier); t != nil {
				tier = t.Name
			}
			icon := "item:" + it.Tier
			if it.Art != "" {
				icon = "items/painted/" + it.Art
			}
			out = append(out, Line{Kind: "item", ID: it.DefID, Amount: 1,
				Text: fmt.Sprintf("%s (%s)", it.Name, tier), Icon: icon, Tier: it.Tier})
		}
	}
	return out
}

// Merge is two rewards as one: the sums of what they count, and every piece of
// gear, cosmetic and boost of both. A letter that carries what a season or a
// festival left unclaimed carries the merge of its rewards.
func Merge(a, b gameconfig.RewardBundle) gameconfig.RewardBundle {
	out := gameconfig.RewardBundle{
		Diamonds: a.Diamonds + b.Diamonds, Gold: a.Gold + b.Gold, XP: a.XP + b.XP,
		GoldWages: a.GoldWages + b.GoldWages, XPWages: a.XPWages + b.XPWages, Favour: a.Favour + b.Favour,
	}
	if len(a.Tokens)+len(b.Tokens) > 0 {
		out.Tokens = map[string]int64{}
		for k, v := range a.Tokens {
			out.Tokens[k] += v
		}
		for k, v := range b.Tokens {
			out.Tokens[k] += v
		}
	}
	out.Items = append(append(out.Items, a.Items...), b.Items...)
	seen := map[string]bool{}
	for _, c := range append(append([]string{}, a.Cosmetics...), b.Cosmetics...) {
		if !seen[c] {
			seen[c] = true
			out.Cosmetics = append(out.Cosmetics, c)
		}
	}
	out.Boosts = append(append(out.Boosts, a.Boosts...), b.Boosts...)
	return out
}
