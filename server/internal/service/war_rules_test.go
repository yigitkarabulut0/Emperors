package service

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// A war attack moves nothing of a lord's own.
//
// No gold is stolen, no energy is spent, no shield is applied and none breaks,
// no cooldown is touched, no revenge token is granted and no reputation is
// earned per attack. THAT LIST IS THE FEATURE: it is what lets a lord throw
// themselves at the biggest name on the other side without counting the cost,
// and what stops a war from being a raid with a banner on it. The Honour Arena
// is held the same way and for the same reason (arena_test.go).
func TestAWarAttackTouchesNothingOfTheLordsOwn(t *testing.T) {
	src, err := os.ReadFile("war.go")
	if err != nil {
		t.Fatal(err)
	}
	code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(src), "")
	for name, why := range map[string]string{
		"ApplyBattleDefender": "a war attack moves no gold",
		"GrantRevenge":        "a war attack is not a grudge",
		"TouchCooldown":       "a war has its own limit: three a day",
		"settleEnergy":        "a war attack costs no energy",
		"economy.Spend":       "a war attack costs no energy",
		"raidTake":            "a war attack steals nothing",
		"raidCap":             "there is nothing to cap: nothing is taken",
		"ShieldUntil":         "a shield guards against raids, not against the war",
		"ShieldedUntil":       "a shield guards against raids, not against the war",
		"awardReputation":     "renown is the KINGDOM'S, paid once when the war is settled",
	} {
		if strings.Contains(code, name) {
			t.Errorf("war.go names %s -- %s", name, why)
		}
	}
}

// And a war attack never moves the lord's sequence.
//
// Nothing of theirs moves, so the action_seq the client's queued collects are
// counting on must not move either: the client adopts the answer the way it
// adopts a claimed letter. The one ActionSeq a war file may name is none.
func TestAWarAttackLeavesTheSequenceAlone(t *testing.T) {
	for _, file := range []string{"war.go"} {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(src), "")
		if strings.Contains(code, "ActionSeq") {
			t.Errorf("%s writes action_seq: a war attack moves nothing of the lord's own, "+
				"so it must not move the number the client's collects are queued behind", file)
		}
	}
}

// The beast's blow is the opposite case, and it is worth saying so: it SPENDS
// energy, so it is sequenced, and it must go through the one statement that
// spends and sequences together.
func TestABlowAtTheBeastSpendsEnergyThroughTheSequencedStatement(t *testing.T) {
	src, err := os.ReadFile("boss.go")
	if err != nil {
		t.Fatal(err)
	}
	code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(src), "")
	if !strings.Contains(code, "SpendEnergySeq") {
		t.Error("boss.go does not spend energy through SpendEnergySeq: a blow that spent " +
			"energy without moving the sequence would let a queued collect spend it twice")
	}
	// And nothing else in the file may carry a sequence.
	for _, loc := range regexp.MustCompile(`ActionSeq:`).FindAllStringIndex(code, -1) {
		window := code[maxInt(0, loc[0]-240):loc[0]]
		if !strings.Contains(window, "SpendEnergySeq") {
			t.Errorf("boss.go writes action_seq somewhere it may not: ...%s",
				window[maxInt(0, len(window)-90):])
		}
	}
}
