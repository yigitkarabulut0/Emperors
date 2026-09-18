package service

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/combat"
	"github.com/yigitkarabulut0/emperors/server/internal/game/estates"
)

// The Attack tab's "steal up to" is what the raid pays, War Chest and all.
//
// They were two calls: the preview applied the War Chest and the raid did not,
// so the upgrade raised a number on the screen and never the gold. Both now go
// through raidTake, and this pins that the War Chest actually reaches it.
func TestTheWarChestRaisesTheTake(t *testing.T) {
	d := seedDeps(t)
	rich := int64(50_000_000) // enough that the level cap, not the purse, decides
	for _, level := range []int64{10, 30, 60} {
		plain := d.raidTake(level, rich, estates.Effects{}, false)
		chest := d.raidTake(level, rich, estates.Effects{StealCapBP: 6400}, false)
		if chest <= plain {
			t.Fatalf("level %d: a +64%% War Chest takes %d, no more than %d without it", level, chest, plain)
		}
		if want := plain * 16400 / 10000; chest < want-1 || chest > want+1 {
			t.Fatalf("level %d: a +64%% War Chest takes %d, want about %d", level, chest, want)
		}
	}
}

// A revenge strike takes a third more, and never more than the purse holds.
func TestRevengeTakesMoreButNeverThePurse(t *testing.T) {
	d := seedDeps(t)
	eff := estates.Effects{}
	for _, gold := range []int64{0, 5, 300, 10_000, 50_000_000} {
		plain := d.raidTake(30, gold, eff, false)
		avenge := d.raidTake(30, gold, eff, true)
		if avenge < plain {
			t.Fatalf("gold %d: revenge takes %d, less than a raid's %d", gold, avenge, plain)
		}
		if avenge > gold {
			t.Fatalf("gold %d: revenge takes %d, more than they hold", gold, avenge)
		}
	}
}

// Ransom Coffers raise the ransom a held defence pays. They were on sale and
// applied to nothing.
func TestRansomCoffersRaiseTheRansom(t *testing.T) {
	d := seedDeps(t)
	plain := d.raidRansom(30, 1_000_000, estates.Effects{})
	coffers := d.raidRansom(30, 1_000_000, estates.Effects{RansomBP: 4000})
	if plain <= 0 {
		t.Fatalf("a held defence pays no ransom (%d)", plain)
	}
	if coffers <= plain {
		t.Fatalf("+40%% Ransom Coffers pay %d, no more than %d", coffers, plain)
	}
	// The raider's War Chest is theirs and says nothing about the defence.
	if got := d.raidRansom(30, 1_000_000, estates.Effects{StealCapBP: 6400}); got != plain {
		t.Fatalf("the raider's War Chest moved the defender's ransom: %d vs %d", got, plain)
	}
}

// The revenge price is half, never zero, and the one number both the list and
// the raid use.
func TestRevengeCostsHalfAndNeverNothing(t *testing.T) {
	d := seedDeps(t)
	for level := int64(1); level <= 60; level++ {
		full := d.attackEnergyCost(level)
		half := d.revengeEnergyCost(level)
		if half < 1 || half > full {
			t.Fatalf("level %d: revenge costs %d of %d", level, half, full)
		}
		if half != full/2 && !(full/2 == 0 && half == 1) {
			t.Fatalf("level %d: revenge costs %d, want %d", level, half, full/2)
		}
	}
}

// Nothing in the attack code works the take or the ransom out a second way.
//
// The shape of the War Chest bug was a second call site with different
// arguments. Guarded the way purity_test.go guards internal/game: by reading
// the source, because a second call compiles perfectly well.
func TestTheTakeIsWorkedOutInOnePlace(t *testing.T) {
	src, err := os.ReadFile("attack.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	for fn, allowed := range map[string][]string{
		"estimateStealWithCap(": {"func (d Deps) estimateSteal(", "func (d Deps) raidTake("},
		"estimateSteal(":        {"func (d Deps) raidRansom("},
	} {
		for _, loc := range regexp.MustCompile(regexp.QuoteMeta("d."+fn)).FindAllStringIndex(body, -1) {
			owner := enclosingFunc(body, loc[0])
			ok := false
			for _, a := range allowed {
				if strings.HasPrefix(owner, a) {
					ok = true
				}
			}
			if !ok {
				t.Fatalf("d.%s called from %q -- route it through raidTake or raidRansom", fn, owner)
			}
		}
	}
}

func enclosingFunc(src string, at int) string {
	i := strings.LastIndex(src[:at], "\nfunc ")
	if i < 0 {
		return ""
	}
	line := src[i+1:]
	if j := strings.IndexByte(line, '\n'); j >= 0 {
		line = line[:j]
	}
	return line
}

// A stored battle read back by the lord who was raided is their defence: their
// side, their result, the gold that left their purse.
func TestAReplayIsToldFromTheReadersSide(t *testing.T) {
	raider, victim := uuid.New(), uuid.New()
	rep := &combat.Replay{}

	// The raid succeeded and took 300.
	won := sqlcdb.AppBattle{ID: uuid.New(), AttackerID: raider, DefenderID: victim,
		AttackerWon: true, GoldStolen: 300, XpAwarded: 12}
	if v := battleReplayView(won, raider, rep); v.Perspective != "attacker" || !v.Won || v.Gold != 300 || v.XPGained != 12 {
		t.Fatalf("the raider's view: %+v", v)
	}
	if v := battleReplayView(won, victim, rep); v.Perspective != "defender" || v.Won || v.Gold != -300 || v.XPGained != 0 {
		t.Fatalf("the victim's view: %+v", v)
	}

	// The raid failed and the defence was paid a ransom of 40.
	held := sqlcdb.AppBattle{ID: uuid.New(), AttackerID: raider, DefenderID: victim,
		AttackerWon: false, RansomPaid: 40, XpAwarded: 4}
	if v := battleReplayView(held, raider, rep); v.Won || v.Gold != 0 || v.RansomPaid != 40 {
		t.Fatalf("the failed raider's view: %+v", v)
	}
	if v := battleReplayView(held, victim, rep); !v.Won || v.Gold != 40 {
		t.Fatalf("the defender who held: %+v", v)
	}
}

// The Attack tab opens at a level, and the raid band never reaches below it.
func TestNobodyUnderTheAttackTabIsATarget(t *testing.T) {
	d := seedDeps(t)
	at := d.Config.SectionLevel(fightSection)
	if at <= 1 {
		t.Fatalf("the seed gates the Attack tab at %d; this test assumes a real gate", at)
	}
	if got := d.Config.SectionLevel("no_such_section"); got != 1 {
		t.Fatalf("an ungated section reads %d, want 1", got)
	}
	for level := int32(1); level <= 60; level++ {
		lo, hi := raidBand(level, int32(at))
		if lo > hi {
			continue
		}
		if lo < int32(at) {
			t.Fatalf("a level-%d raider is offered targets from level %d, under the tab's %d", level, lo, at)
		}
		if level >= int32(at) && (lo > level || hi < level) {
			t.Fatalf("a level-%d raider's band %d..%d does not contain their own level", level, lo, hi)
		}
	}
	// Under the gate yourself, there is nobody to offer.
	if lo, hi := raidBand(int32(at)-1, int32(at)); lo <= hi {
		t.Fatalf("a lord under the gate is offered levels %d..%d", lo, hi)
	}
	// The case that shipped: a level-10 raider drew from 6..14.
	if lo, _ := raidBand(int32(at), int32(at)); lo != int32(at) {
		t.Fatalf("a raider at the gate draws from %d", lo)
	}
}

// The hero Family shows is the hero the Army fights with.
func TestFamilyAndArmyAgreeOnTheHero(t *testing.T) {
	d := seedDeps(t)
	p := sqlcdb.AppPlayer{ID: uuid.New(), Level: 30, StatAttack: 0, StatDefense: 0, StatEnergy: 20}
	gear := map[string]*ItemView{"weapon": {Attack: 120, Defense: 10}, "armor": nil, "horse": {Attack: 20, Defense: 20, Speed: 30}}
	hs := d.heroStats(p, gear)
	u := d.heroUnit(p, gear)
	if hs.Attack != u.Attack || hs.Defense != u.Defense || hs.Speed != u.Speed || hs.Power != u.Might {
		t.Fatalf("Family says %+v, the Army fights with atk %d def %d spd %d might %d",
			hs, u.Attack, u.Defense, u.Speed, u.Might)
	}
	// All points in energy and nothing worn used to read 0 / 0 / 0.
	bare := d.heroStats(p, map[string]*ItemView{"weapon": nil, "armor": nil, "horse": nil})
	if bare.Attack <= 0 || bare.Defense <= 0 || bare.Power <= 0 {
		t.Fatalf("a level-30 hero with nothing worn reads %+v", bare)
	}
}

// The rate a revenge card prints is the rate the revenge strike takes.
func TestTheRevengeRateIsTheRevengeTake(t *testing.T) {
	d := seedDeps(t)
	gold := int64(100_000) // small enough that the rate, not the cap, decides
	take := d.raidTake(60, gold, estates.Effects{}, true)
	if printed := gold * revengeRateBP / 10000; take < printed-2 || take > printed+2 {
		t.Fatalf("the card says %d bp (%d gold), the strike takes %d", revengeRateBP, printed, take)
	}
}

// The ceiling on a won fight is worked out in exactly one place.
//
// It was a literal inside estimateStealWithCap, which was fine while the raid
// was the only thing that used it. The bounty board pays a multiple of it, and
// the War Chest bug was precisely this shape: two call sites with different
// arguments, one of which the player read and the other of which the game ran
// on. Guarded by reading the source, because a second copy compiles.
func TestTheRaidCapIsWorkedOutInOnePlace(t *testing.T) {
	var body string
	for _, f := range []string{"attack.go", "bounty.go", "arena.go"} {
		src, err := os.ReadFile(f)
		if err != nil {
			continue // not written yet
		}
		body += string(src)
	}
	for _, lit := range []string{"raidCapBase", "raidCapPerLevelBP"} {
		for _, loc := range regexp.MustCompile(lit).FindAllStringIndex(body, -1) {
			owner := enclosingFunc(body, loc[0])
			if owner != "" && !strings.HasPrefix(owner, "func raidCap(") {
				t.Fatalf("%s used from %q -- the ceiling is raidCap's alone", lit, owner)
			}
		}
	}
	// The old literal is gone for good. Comments are stripped first, because
	// raidCap's own doc quotes the formula it replaced.
	code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(body, "")
	if regexp.MustCompile(`10000\s*\+\s*3500\s*\*`).MatchString(code) {
		t.Fatal("the raid cap's formula is written out again somewhere -- call raidCap")
	}
	i := strings.Index(body, "func (d Deps) estimateStealWithCap(")
	if i < 0 {
		t.Fatal("estimateStealWithCap is gone")
	}
	if !strings.Contains(body[i:i+400], "raidCap(") {
		t.Fatal("estimateStealWithCap no longer reads raidCap")
	}
}

// And the value itself, so the extraction cannot have quietly changed it.
func TestTheRaidCapIsTheNumberItWas(t *testing.T) {
	for _, c := range []struct{ level, want int64 }{{1, 337}, {10, 1125}, {30, 2875}, {60, 5500}} {
		if got := raidCap(c.level); got != c.want {
			t.Fatalf("level %d: raidCap %d, want %d", c.level, got, c.want)
		}
	}
}
