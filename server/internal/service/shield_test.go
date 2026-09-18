package service

import (
	"strings"
	"testing"
	"time"
)

// Raiding ends your own protection; a revenge strike keeps it.
//
// The shield used to survive the raider's own attacks, so the eight-hour one in
// the store bought the right to raid while nobody could answer.
func TestRaidingEndsYourOwnShield(t *testing.T) {
	until := time.Date(2026, 9, 14, 20, 0, 0, 0, time.UTC)

	if got := attackerShieldAfter(false, &until); got != nil {
		t.Fatalf("an ordinary raid left the raider shielded until %v", *got)
	}
	if got := attackerShieldAfter(false, nil); got != nil {
		t.Fatalf("an unshielded raider came out of a raid shielded until %v", *got)
	}
	got := attackerShieldAfter(true, &until)
	if got == nil || !got.Equal(until) {
		t.Fatalf("a revenge strike changed the raider's shield to %v, want %v kept", got, until)
	}
	if got := attackerShieldAfter(true, nil); got != nil {
		t.Fatalf("a revenge strike granted a shield the raider did not have: %v", *got)
	}
}

// The rule is only a rule if the raid writes it: the query must set the column
// every time, and the raid must hand it the rule's answer.
func TestTheRaidWritesTheRaidersShield(t *testing.T) {
	stmt := queryStatement(t, "battles.sql", "ApplyBattleAttacker")
	if !strings.Contains(stmt, "shield_until = sqlc.narg(shield_until)") {
		t.Fatalf("ApplyBattleAttacker no longer writes the raider's shield:\n%s", stmt)
	}
	src := serviceSource(t, "attack.go")
	if !strings.Contains(src, "ShieldUntil: attackerShieldAfter(avenging, me.ShieldUntil)") {
		t.Fatal("the raid no longer passes attackerShieldAfter to ApplyBattleAttacker")
	}
}

// The shield is sold with the one way it ends early, and the rules sheet says so.
func TestTheShieldIsSoldWithItsRule(t *testing.T) {
	if !strings.Contains(serviceSource(t, "store.go"), "Raiding someone yourself ends it.") {
		t.Fatal("the store's shield no longer tells the buyer that raiding ends it")
	}
	if !strings.Contains(serviceSource(t, "attack.go"), "ShieldBreaks:    true") {
		t.Fatal("the raid rules no longer report that raiding ends the raider's shield")
	}
}
