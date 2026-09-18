package experiments

import (
	"fmt"
	"math"
	"testing"
)

// The same lord is always in the same arm, and many lords split by weight.
func TestAssignIsStableAndWeighted(t *testing.T) {
	arms := []Arm{{"control", 70}, {"b", 30}}
	secret := []byte("ab-test")
	if a, b := Assign(secret, "t", "lord-1", arms), Assign(secret, "t", "lord-1", arms); a != b {
		t.Fatalf("one lord in two arms: %s, %s", a, b)
	}
	counts := map[string]int{}
	const n = 20000
	for i := 0; i < n; i++ {
		counts[Assign(secret, "t", fmt.Sprintf("lord-%d", i), arms)]++
	}
	if got := float64(counts["control"]) / n; math.Abs(got-0.70) > 0.015 {
		t.Fatalf("control drew %.3f of lords, want 0.70", got)
	}
	// Another test splits the same lords independently.
	same := 0
	for i := 0; i < 1000; i++ {
		p := fmt.Sprintf("lord-%d", i)
		if Assign(secret, "t", p, arms) == Assign(secret, "u", p, arms) {
			same++
		}
	}
	if same > 700 || same < 450 {
		t.Fatalf("two tests put %d of 1000 lords in the same arm; they should be independent (~580)", same)
	}
	if Assign(secret, "t", "x", []Arm{{"a", 0}}) != "" {
		t.Fatal("an arm with no weight was chosen")
	}
}

// The z statistic reads the textbook example right, and is zero with no data.
func TestZScore(t *testing.T) {
	// 200/1000 against 250/1000: z = 2.68 (two-proportion, pooled).
	if z := ZScore(1000, 200, 1000, 250); math.Abs(z-2.68) > 0.01 {
		t.Fatalf("z = %.3f, want 2.68", z)
	}
	if ZScore(0, 0, 10, 1) != 0 || ZScore(10, 0, 10, 0) != 0 {
		t.Fatal("no data gave a z score")
	}
}
