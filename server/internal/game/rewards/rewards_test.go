package rewards

import (
	"strings"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

func seed(t *testing.T) *gameconfig.Bundle {
	t.Helper()
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Wages are paid at the best job the player can do, so the same reward is the
// same share of a day's play at every level.
func TestWagesScaleWithTheBestJob(t *testing.T) {
	cfg := seed(t)
	b := gameconfig.RewardBundle{GoldWages: 60, XPWages: 60}
	low := Resolve(cfg, b, 1, economy.Bonuses{})
	high := Resolve(cfg, b, 60, economy.Bonuses{})
	if low.Gold <= 0 || high.Gold <= low.Gold*5 {
		t.Fatalf("60 energy of wages pays %d at level 1 and %d at level 60; the late job must pay far more", low.Gold, high.Gold)
	}
	job := BestJob(cfg, 60)
	if want := job.BaseGold * 60 / job.EnergyCost; high.Gold != want {
		t.Fatalf("level-60 wages %d, want %d (60 energy at %s)", high.Gold, want, job.ID)
	}
}

// A reward is worth what it is worth at any hour: a live event does not lift it.
func TestWagesIgnoreTimedBonuses(t *testing.T) {
	cfg := seed(t)
	b := gameconfig.RewardBundle{GoldWages: 100}
	var perm, both economy.Bonuses
	perm.Add(economy.BucketCollectIncome, 5000)
	both = perm
	both.AddTemp(economy.BucketCollectIncome, 10000)
	if a, c := Resolve(cfg, b, 30, perm), Resolve(cfg, b, 30, both); a.Gold != c.Gold {
		t.Fatalf("an event changed a reward from %d to %d gold", a.Gold, c.Gold)
	}
	if a, c := Resolve(cfg, b, 30, economy.Bonuses{}), Resolve(cfg, b, 30, perm); c.Gold <= a.Gold {
		t.Fatalf("the permanent Granary bonus did not reach wages: %d vs %d", a.Gold, c.Gold)
	}
}

// The best job is the best gold per energy the level allows.
func TestBestJobIsTheTopUnlockedRung(t *testing.T) {
	cfg := seed(t)
	for _, c := range []struct {
		level int
		want  string
	}{{1, "grapes"}, {5, "wheat"}, {60, "dragon_hoard"}} {
		if got := BestJob(cfg, c.level); got == nil || got.ID != c.want {
			t.Fatalf("level %d best job %v, want %s", c.level, got, c.want)
		}
	}
}

// The same grant rolls the same gear: retrying a claim cannot reroll it.
func TestItemsAreSeededByTheGrant(t *testing.T) {
	cfg := seed(t)
	grants := []gameconfig.ItemGrant{{Tier: "rare", Count: 3}, {Slot: "horse", Tier: "epic", Count: 1}}
	a := Items(cfg, []byte("secret"), "mail:42", 30, 0, grants)
	b := Items(cfg, []byte("secret"), "mail:42", 30, 0, grants)
	c := Items(cfg, []byte("secret"), "mail:43", 30, 0, grants)
	if len(a) != 4 {
		t.Fatalf("rolled %d items, want 4", len(a))
	}
	same := true
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("item %d differs between two rolls of the same grant", i)
		}
		if a[i] != c[i] {
			same = false
		}
		if a[i].Ilvl != 30 {
			t.Fatalf("item %d rolled at level %d, want the player's 30", i, a[i].Ilvl)
		}
	}
	if same {
		t.Fatal("two different grants rolled identical gear")
	}
	if a[3].Slot != "horse" || a[3].Tier != "epic" {
		t.Fatalf("the slotted grant rolled %s %s", a[3].Tier, a[3].Slot)
	}
}

// The words are the server's, resolved for this player.
func TestLinesSayWhatArrives(t *testing.T) {
	cfg := seed(t)
	b := gameconfig.RewardBundle{
		Diamonds: 1200, GoldWages: 60,
		Tokens: map[string]int64{"energy_potion": 2},
		Items:  []gameconfig.ItemGrant{{Tier: "rare", Count: 1}},
		Boosts: []gameconfig.BoostGrant{{Bucket: gameconfig.BucketXP, BP: 5000, Hours: 24}},
	}
	lines := Lines(cfg, b, Resolve(cfg, b, 20, economy.Bonuses{}))
	want := map[string]string{
		"diamonds": "1,200 diamonds",
		"token":    "2 Energy Potions",
		"item":     "Rare gear",
		"boost":    "+50% experience for 24 hours",
	}
	seen := map[string]bool{}
	for _, l := range lines {
		seen[l.Kind] = true
		if w, ok := want[l.Kind]; ok && l.Text != w {
			t.Errorf("%s line reads %q, want %q", l.Kind, l.Text, w)
		}
		if l.Icon == "" {
			t.Errorf("%s line has no icon", l.Kind)
		}
	}
	if !seen["gold"] {
		t.Error("wages produced no gold line")
	}
}

// A cosmetic's line carries the crop its catalogue names, so the client draws
// it without a catalogue of its own.
func TestACosmeticLineCarriesItsArt(t *testing.T) {
	cfg := seed(t)
	c := cfg.Cosmetic("crest_lion")
	if c == nil || c.Art == "" {
		t.Skip("the catalogue has no cosmetic with art to test against")
	}
	b := gameconfig.RewardBundle{Cosmetics: []string{"crest_lion"}}
	lines := Lines(cfg, b, Resolve(cfg, b, 20, economy.Bonuses{}))
	if len(lines) != 1 || lines[0].Icon != c.Art {
		t.Fatalf("the crest's line: %+v, want icon %q", lines, c.Art)
	}
}

// A name colour's line carries the colour, and a title's names its kind, so
// neither falls back to a stock icon.
func TestANameColourLineCarriesItsColour(t *testing.T) {
	cfg := seed(t)
	c := cfg.Cosmetic("color_emerald")
	if c == nil || c.Color == "" {
		t.Fatal("the catalogue has lost color_emerald")
	}
	b := gameconfig.RewardBundle{Cosmetics: []string{"color_emerald", "title_founder"}}
	lines := Lines(cfg, b, Resolve(cfg, b, 20, economy.Bonuses{}))
	if len(lines) != 2 || lines[0].Color != c.Color || lines[0].Icon != "name_color:color_emerald" {
		t.Fatalf("the colour's line: %+v, want colour %s", lines, c.Color)
	}
	if !strings.HasSuffix(lines[0].Text, "(name colour)") {
		t.Fatalf("the colour's line says %q; the game spells it colour", lines[0].Text)
	}
	if lines[1].Icon != "title:title_founder" || lines[1].Color != "" {
		t.Fatalf("the title's line: %+v", lines[1])
	}
}

func TestGroup(t *testing.T) {
	for n, want := range map[int64]string{0: "0", 999: "999", 1000: "1,000", 1234567: "1,234,567", -4500: "-4,500"} {
		if got := Group(n); got != want {
			t.Errorf("Group(%d) = %q, want %q", n, got, want)
		}
	}
}

// Once gear is rolled, each piece is named with its own design as the icon;
// before, the rarity line stands. Every other line keeps its place.
func TestRolledGearIsNamed(t *testing.T) {
	cfg := seed(t)
	b := gameconfig.RewardBundle{Diamonds: 5, Items: []gameconfig.ItemGrant{{Tier: "rare", Count: 2}}}
	lines := Lines(cfg, b, Resolved{})
	if got := RolledLines(cfg, lines, nil); len(got) != len(lines) || got[len(got)-1].Icon != "item:rare" || got[len(got)-1].Tier != "rare" {
		t.Fatalf("before the roll the rarity line changed: %+v", got)
	}
	rolled := Items(cfg, []byte("secret"), "mail:7", 20, 0, b.Items)
	got := RolledLines(cfg, lines, rolled)
	if len(got) != 1+len(rolled) || got[0].Kind != "diamonds" {
		t.Fatalf("after the roll: %+v", got)
	}
	for i, it := range rolled {
		l := got[1+i]
		if l.Kind != "item" || l.ID != it.DefID || l.Icon != "items/painted/"+it.Art || l.Amount != 1 || l.Tier != it.Tier {
			t.Fatalf("line %d for %s: %+v", i, it.DefID, l)
		}
		if l.Text == "" || l.Text == "Rare gear" {
			t.Fatalf("line %d does not name the piece: %q", i, l.Text)
		}
	}
}

// Two rewards merged pay what both would: counts summed, gear and looks kept,
// a cosmetic in both given once.
func TestMergeKeepsEverything(t *testing.T) {
	a := gameconfig.RewardBundle{Diamonds: 10, GoldWages: 20, Tokens: map[string]int64{"cart": 1},
		Items: []gameconfig.ItemGrant{{Tier: "rare", Count: 1}}, Cosmetics: []string{"frame_charter"}}
	b := gameconfig.RewardBundle{Diamonds: 5, Tokens: map[string]int64{"cart": 2, "pardon": 1},
		Cosmetics: []string{"frame_charter", "title_chartered"}}
	m := Merge(a, b)
	if m.Diamonds != 15 || m.GoldWages != 20 || m.Tokens["cart"] != 3 || m.Tokens["pardon"] != 1 ||
		ItemCount(m) != 1 || len(m.Cosmetics) != 2 {
		t.Fatalf("merged %+v", m)
	}
	if a.Tokens["cart"] != 1 {
		t.Fatal("merging changed the first reward")
	}
	if !Merge(gameconfig.RewardBundle{}, gameconfig.RewardBundle{}).Empty() {
		t.Fatal("two empty rewards merged into something")
	}
}
