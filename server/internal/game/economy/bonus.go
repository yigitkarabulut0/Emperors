// Package economy holds the game's money and progression math.
//
// It is PURE: no context, no database, no net/http, and no time.Now(). Time
// always arrives as a parameter. That is what makes the economy unit-testable
// with zero infrastructure, makes the admin panel's balance simulator possible
// (it runs this exact code), and makes every roll reproducible for audit.
//
// All arithmetic is integer. Multipliers are basis points (10000 = 1.0x) and
// rounding is always floor, so the server, the simulator and the client's
// optimistic display agree bit for bit.
package economy

// Bucket names. Every percentage bonus in the game belongs to exactly one
// bucket, and bonuses inside a bucket are ADDITIVE, not multiplicative.
//
// This is the anti-inflation invariant. Multiplicative stacking is the usual
// idle-game convention and it is how these economies die: six +25% upgrades
// become 3.8x, not 2.5x, and the curve runs away from the sinks. Additive
// stacking inside a hard-capped bucket makes the maximum reachable income a
// number you can write down.
type Bucket int

const (
	// BucketCollectIncome scales gold from Collect. Sources: job mastery,
	// Granary, kingdom income upgrades.
	BucketCollectIncome Bucket = iota
	// BucketEnergyRegen scales energy regeneration. This is the single ceiling
	// on the entire gold supply — see the note on Caps below.
	BucketEnergyRegen
	// BucketXPGain scales experience from every source.
	BucketXPGain
	numBuckets
)

// Caps are the hard ceilings, in basis points, on each bucket's total bonus.
//
// BucketEnergyRegen's cap is load-bearing. Energy regenerates at a FLAT rate, so
// daily throughput is bought only here; capping it at +60% is what bounds total
// gold creation. Max Energy deliberately does not appear: it only changes how
// long a player can be away, never how much they earn per day.
var Caps = [numBuckets]int64{
	BucketCollectIncome: 15000, // +150%
	BucketEnergyRegen:   6000,  // +60%
	BucketXPGain:        10000, // +100%
}

// Bonuses is the accumulated basis points per bucket for one player.
type Bonuses [numBuckets]int64

// Add records a bonus in a bucket.
func (b *Bonuses) Add(bucket Bucket, bp int64) { b[bucket] += bp }

// ApplyBucket scales an amount by a bucket's bonus, clamped to that bucket's
// cap, with floor rounding.
//
// This is deliberately the ONLY way a percentage bonus may be applied anywhere
// in the codebase. If a second path appears, the cap stops being a cap.
func ApplyBucket(amount int64, bonuses Bonuses, bucket Bucket) int64 {
	if amount <= 0 {
		return 0
	}
	bp := bonuses[bucket]
	if bp < 0 {
		bp = 0
	}
	if cap := Caps[bucket]; bp > cap {
		bp = cap
	}
	return amount * (10000 + bp) / 10000
}

// EffectiveBP returns a bucket's bonus after clamping — what the UI should show,
// so a player who has stacked past the cap sees the truth rather than a number
// that does nothing.
func EffectiveBP(bonuses Bonuses, bucket Bucket) int64 {
	bp := bonuses[bucket]
	if bp < 0 {
		return 0
	}
	if cap := Caps[bucket]; bp > cap {
		return cap
	}
	return bp
}
