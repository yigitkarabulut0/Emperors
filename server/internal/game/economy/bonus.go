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
	// Granary, kingdom income upgrades, Legacy.
	BucketCollectIncome Bucket = iota
	// BucketEnergyRegen scales energy regeneration. This is the single ceiling
	// on the entire gold supply — see the note on Caps below.
	BucketEnergyRegen
	// BucketXPGain scales experience from every source.
	BucketXPGain

	// The temporary lanes. Every bonus that EXPIRES -- a server event, an hourly
	// event, a draught, a timed reward -- goes here, through AddTemp, never
	// through Add.
	//
	// They exist because the permanent lane fills up. A late player's upgrades,
	// mastery, kingdom and Legacy already reach the +150% collect cap, so an event
	// added into the same bucket gave that player nothing at all: "double gold
	// for an hour" was double gold for the new players and zero for everyone who
	// had played the longest. A timed lane with its own ceiling lets an event lift
	// everyone, while both ceilings stay numbers you can write down: at most
	// +150% permanent plus +200% while something is running.
	//
	// Never passed to ApplyBucket or EffectiveBP directly -- they read a lane
	// through its permanent bucket -- and a test fails the build if one is.
	BucketCollectIncomeTemp
	BucketXPGainTemp
	numBuckets
)

// Caps are the hard ceilings, in basis points, on each bucket's total bonus.
//
// BucketEnergyRegen's cap is load-bearing. Energy regenerates at a FLAT rate, so
// daily throughput is bought only here; capping it at +60% is what bounds total
// gold creation. Max Energy deliberately does not appear: it only changes how
// long a player can be away, never how much they earn per day. It has no
// temporary lane for the same reason: a timed regen boost is a mint.
var Caps = [numBuckets]int64{
	BucketCollectIncome:     15000, // +150%
	BucketEnergyRegen:       6000,  // +60%
	BucketXPGain:            10000, // +100%
	BucketCollectIncomeTemp: 20000, // +200% more, only while timed effects run
	BucketXPGainTemp:        10000, // +100% more, only while timed effects run
}

// Bonuses is the accumulated basis points per bucket for one player.
type Bonuses [numBuckets]int64

// Add records a permanent bonus in a bucket.
func (b *Bonuses) Add(bucket Bucket, bp int64) { b[bucket] += bp }

// AddTemp records a bonus that expires, in the bucket's temporary lane.
//
// A bucket with no temporary lane takes nothing: a timed energy regeneration
// boost is never allowed (see Caps), and ignoring one is safer than letting it
// into the permanent lane.
func (b *Bonuses) AddTemp(perm Bucket, bp int64) {
	if lane, ok := TempLane(perm); ok {
		b[lane] += bp
	}
}

// TempLane is a permanent bucket's temporary lane, if it has one.
func TempLane(perm Bucket) (Bucket, bool) {
	switch perm {
	case BucketCollectIncome:
		return BucketCollectIncomeTemp, true
	case BucketXPGain:
		return BucketXPGainTemp, true
	}
	return perm, false
}

// permanentBP is the permanent lane after its clamp.
func permanentBP(bonuses Bonuses, bucket Bucket) int64 {
	bp := bonuses[bucket]
	if bp < 0 {
		return 0
	}
	if cap := Caps[bucket]; bp > cap {
		return cap
	}
	return bp
}

// TempBP is what the timed lane actually adds to a bucket for this player, after
// its own clamp -- what an event banner says it is worth to them.
//
// It can be negative (an operator's nerf event), but never below minus the
// permanent lane: a nerf can cancel bonuses, never take a payout under base.
func TempBP(bonuses Bonuses, bucket Bucket) int64 {
	lane, ok := TempLane(bucket)
	if !ok {
		return 0
	}
	bp := bonuses[lane]
	if cap := Caps[lane]; bp > cap {
		bp = cap
	}
	if floor := -permanentBP(bonuses, bucket); bp < floor {
		bp = floor
	}
	return bp
}

// EffectiveBP returns a bucket's bonus after clamping both lanes — what the UI
// should show, so a player who has stacked past a cap sees the truth rather
// than a number that does nothing.
func EffectiveBP(bonuses Bonuses, bucket Bucket) int64 {
	return permanentBP(bonuses, bucket) + TempBP(bonuses, bucket)
}

// ApplyBucket scales an amount by a bucket's bonus, each lane clamped to its
// own cap exactly once, with floor rounding.
//
// This is deliberately the ONLY way a percentage bonus may be applied anywhere
// in the codebase. If a second path appears, the cap stops being a cap.
func ApplyBucket(amount int64, bonuses Bonuses, bucket Bucket) int64 {
	if amount <= 0 {
		return 0
	}
	return amount * (10000 + EffectiveBP(bonuses, bucket)) / 10000
}
