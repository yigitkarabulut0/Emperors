package admin

import (
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The panel shows an operator what an event can reach before they start one.
// If that number is not the number the engine enforces, the panel is lying at
// the exact moment someone is deciding what to do -- which is what happened:
// xp_bp was advertised at 20000 while economy.Caps enforced 10000.
//
// An event rides its bucket's TIMED lane (loadEffects adds it with AddTemp), so
// the ceiling that binds it is the timed lane's.
func TestAdvertisedCapsMatchWhatIsEnforced(t *testing.T) {
	enforced := map[string]int64{
		gameconfig.BucketCollectIncome: economy.Caps[economy.BucketCollectIncomeTemp],
		gameconfig.BucketXP:            economy.Caps[economy.BucketXPGainTemp],
		gameconfig.BucketLuck:          gameconfig.MaxLuckBP,
	}
	for _, b := range BoostableBuckets() {
		want, ok := enforced[b.Bucket]
		if !ok {
			t.Errorf("%s is advertised as boostable but nothing here says what enforces it", b.Bucket)
			continue
		}
		if b.CapBP != want {
			t.Errorf("%s advertises a cap of %d, the engine enforces %d", b.Bucket, b.CapBP, want)
		}
	}
}

func TestCapForKnowsEveryBoostableBucket(t *testing.T) {
	for _, b := range BoostableBuckets() {
		if capFor(b.Bucket) != b.CapBP {
			t.Errorf("capFor(%q) = %d, want %d", b.Bucket, capFor(b.Bucket), b.CapBP)
		}
	}
	if capFor("energy_regen_bp") != 0 {
		t.Error("a bucket that is not boostable reports a cap, which would let it past the guard")
	}
}
