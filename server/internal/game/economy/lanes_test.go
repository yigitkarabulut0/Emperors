package economy

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The case the timed lane exists for: a lord whose permanent bonuses are past
// the collect cap still gets a live event.
//
// Before the lane an event added into the same bucket as the Granary, mastery,
// the kingdom and Legacy, so for anyone at +150% it was worth exactly nothing.
func TestAnEventReachesALordAtThePermanentCap(t *testing.T) {
	var b Bonuses
	b.Add(BucketCollectIncome, 16000) // Granary + kingdom + mastery + Legacy: +160%
	base := ApplyBucket(1000, b, BucketCollectIncome)
	if base != 2500 {
		t.Fatalf("a +160%% permanent stack pays %d on 1000, want the +150%% cap: 2500", base)
	}
	b.AddTemp(BucketCollectIncome, 10000) // "Gold Rush": +100%
	if got := ApplyBucket(1000, b, BucketCollectIncome); got != 3500 {
		t.Fatalf("with a +100%% event the lord at the cap gets %d, want 3500", got)
	}
	if TempBP(b, BucketCollectIncome) != 10000 {
		t.Fatalf("the banner would say +%d bp, want +10000", TempBP(b, BucketCollectIncome))
	}
}

// Each lane keeps its own ceiling: the timed one never lifts the permanent one
// past its cap, and neither spills into the other.
func TestEachLaneKeepsItsOwnCeiling(t *testing.T) {
	var b Bonuses
	b.AddTemp(BucketCollectIncome, 50000) // absurd stacked events
	if got := EffectiveBP(b, BucketCollectIncome); got != Caps[BucketCollectIncomeTemp] {
		t.Fatalf("timed lane alone reached %d bp, want its cap %d", got, Caps[BucketCollectIncomeTemp])
	}
	b.Add(BucketCollectIncome, 50000)
	want := Caps[BucketCollectIncome] + Caps[BucketCollectIncomeTemp]
	if got := EffectiveBP(b, BucketCollectIncome); got != want {
		t.Fatalf("both lanes stacked absurdly reach %d bp, want the two caps summed: %d", got, want)
	}
	// The absolute ceiling is a number you can write down: 4.5x base gold.
	if got := ApplyBucket(1000, b, BucketCollectIncome); got != 4500 {
		t.Fatalf("the most a collect can ever pay is %d on 1000, want 4500", got)
	}

	var x Bonuses
	x.AddTemp(BucketXPGain, 30000)
	x.Add(BucketXPGain, 30000)
	if got := ApplyBucket(100, x, BucketXPGain); got != 300 {
		t.Fatalf("experience maxes at %d on 100, want 3x: 300", got)
	}
}

// A nerf event can cancel bonuses but never take a payout under base.
func TestANerfNeverGoesBelowBase(t *testing.T) {
	var b Bonuses
	b.Add(BucketCollectIncome, 3000)
	b.AddTemp(BucketCollectIncome, -8000)
	if got := ApplyBucket(1000, b, BucketCollectIncome); got != 1000 {
		t.Fatalf("a -80%% event over +30%% pays %d on 1000, want base 1000", got)
	}
	if got := TempBP(b, BucketCollectIncome); got != -3000 {
		t.Fatalf("the nerf's visible effect is %d bp, want -3000 (it only cancels)", got)
	}
}

// Energy regeneration has no timed lane: a timed regen boost is a mint.
func TestRegenTakesNoTimedBonus(t *testing.T) {
	var b Bonuses
	b.AddTemp(BucketEnergyRegen, 5000)
	if got := EffectiveBP(b, BucketEnergyRegen); got != 0 {
		t.Fatalf("a timed regen bonus reached %d bp", got)
	}
	if _, ok := TempLane(BucketEnergyRegen); ok {
		t.Fatal("energy regeneration grew a timed lane")
	}
}

// With nothing timed running the lanes change nothing: every payout the game
// made before the lane existed is the payout it makes now.
func TestNoTimedBonusIsTheOldRule(t *testing.T) {
	for _, bp := range []int64{-500, 0, 1, 7500, 15000, 40000} {
		var b Bonuses
		b.Add(BucketCollectIncome, bp)
		old := bp
		if old < 0 {
			old = 0
		}
		if old > Caps[BucketCollectIncome] {
			old = Caps[BucketCollectIncome]
		}
		if got, want := ApplyBucket(12345, b, BucketCollectIncome), int64(12345)*(10000+old)/10000; got != want {
			t.Fatalf("permanent %d bp pays %d, the old rule paid %d", bp, got, want)
		}
	}
}

// No call site anywhere names a timed lane in ApplyBucket or EffectiveBP. The
// lanes are read through their permanent bucket; naming one directly would apply
// the timed lane alone, with the permanent bonuses silently dropped.
func TestNoCallSiteNamesATimedLane(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	var dirs []string
	_ = filepath.Walk(filepath.Join(root, "internal"), func(p string, info os.FileInfo, err error) error {
		if err == nil && info.IsDir() {
			dirs = append(dirs, p)
		}
		return nil
	})
	calls := 0
	for _, dir := range dirs {
		files, _ := filepath.Glob(filepath.Join(dir, "*.go"))
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			file, err := parser.ParseFile(token.NewFileSet(), f, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(file, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				var name string
				switch fn := call.Fun.(type) {
				case *ast.Ident:
					name = fn.Name
				case *ast.SelectorExpr:
					name = fn.Sel.Name
				}
				if name != "ApplyBucket" && name != "EffectiveBP" {
					return true
				}
				calls++
				for _, arg := range call.Args {
					ast.Inspect(arg, func(m ast.Node) bool {
						if id, ok := m.(*ast.Ident); ok && strings.HasSuffix(id.Name, "Temp") &&
							strings.HasPrefix(id.Name, "Bucket") {
							t.Errorf("%s names the timed lane %s in %s", f, id.Name, name)
						}
						return true
					})
				}
				return true
			})
		}
	}
	if calls < 5 {
		t.Fatalf("found %d ApplyBucket/EffectiveBP calls; the scan is not seeing the code", calls)
	}
}
