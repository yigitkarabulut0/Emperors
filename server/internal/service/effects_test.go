package service

import (
	"strings"
	"testing"
)

// Everything that expires rides a bucket's timed lane.
//
// Server events and the Kingdom Shop draught used to add into the permanent
// lane, where a lord whose upgrades already filled the cap got nothing from
// them. loadEffects is the one place effects are folded in, so it is held here.
func TestTimedEffectsRideTheTimedLane(t *testing.T) {
	src := serviceSource(t, "estates.go")
	i := strings.Index(src, "func (d Deps) loadEffects(")
	if i < 0 {
		t.Fatal("loadEffects is gone from estates.go")
	}
	body := src[i:]
	if j := strings.Index(body, "\n}\n"); j >= 0 {
		body = body[:j]
	}
	for _, want := range []string{
		// The operator's boosts, the hour's event and the festival: one filing.
		"addLiveBonus(&eff, bucket, bp)",
		"addLiveBonus(&eff, h.Event.Effect.Bucket, h.Event.Effect.BP)",
		"addLiveBonus(&eff, f.Tpl.Effect.Bucket, f.Tpl.Effect.BP)",
		"eff.Bonuses.AddTemp(economy.BucketXPGain, int64(p.XpBoostBp))",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("loadEffects no longer adds a timed effect to the timed lane: %s", want)
		}
	}
	if strings.Contains(body, "eff.Bonuses.Add(economy.BucketXPGain, int64(p.XpBoostBp))") {
		t.Error("the draught is back in the permanent lane")
	}

	// And the filing puts gold and experience in the timed lanes.
	k := strings.Index(src, "func addLiveBonus(")
	if k < 0 {
		t.Fatal("addLiveBonus is gone from estates.go")
	}
	filing := src[k:]
	if j := strings.Index(filing, "\n}\n"); j >= 0 {
		filing = filing[:j]
	}
	for _, want := range []string{
		"eff.Bonuses.AddTemp(economy.BucketCollectIncome, bp)",
		"eff.Bonuses.AddTemp(economy.BucketXPGain, bp)",
	} {
		if !strings.Contains(filing, want) {
			t.Errorf("addLiveBonus no longer files a timed bonus in the timed lane: %s", want)
		}
	}
	if strings.Contains(filing, "eff.Bonuses.Add(") {
		t.Error("addLiveBonus files a timed bonus in a permanent lane")
	}
}
