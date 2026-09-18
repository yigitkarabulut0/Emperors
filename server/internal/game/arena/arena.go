// Package arena is the Honour Arena's arithmetic: the rating two lords trade
// after a fight, the league a rating stands in, the band a lord is matched
// inside, and where a rating starts the next season.
//
// Pure, and deliberately ignorant of gameconfig: Rules and []Tier are plain
// structs the service builds from the balance. That keeps the ladder
// unit-testable with zero infrastructure and lets the panel's simulator run the
// real code.
//
// Integer throughout. Elo's 1/(1+10^(d/400)) is a float, and a float in the
// ladder would let two builds disagree in the fourth decimal and then, after a
// thousand fights, on a league. The curve is kept as a table of expected scores
// in basis points, interpolated -- exact to a quarter of a per cent, which is
// finer than Elo's own precision -- and mirrored so that
//
//	ExpectedBP(a, b) + ExpectedBP(b, a) == 10000
//
// EXACTLY, for every pair. That symmetry is what makes it impossible to mint a
// rating by alternating who attacks, which is the one arithmetic bug that would
// break the ladder silently.
package arena

// Rules is the balance's arena numbers, as this package needs them.
type Rules struct {
	// Start is where a lord (and a fresh season) begins; Floor is the number a
	// rating can never fall through, so a bad week cannot put the arena out of
	// reach; Ceiling is the highest a rating may reach (the column's own check).
	Start, Floor, Ceiling int
	// K is the winner's swing at an even match. DefenderKBP is the share of it
	// the DEFENDER moves: a lord fought while asleep did not choose the fight
	// and must not fall as far as the one who did. The price is that the ladder
	// is not zero-sum and inflates, and HalfReset is what pays for it.
	K           int
	DefenderKBP int64
	// ResetBP is how much of the distance from Start a rating KEEPS when a
	// season turns: 5000 is half way back.
	ResetBP int64
}

// Tier is one league of the ladder.
type Tier struct {
	ID, Name, Emblem string
	// Cosmetic is a frame worn while the league is held; empty for none.
	Cosmetic string
	// AtRating is the rating it opens at. TopN, when set, ALSO demands a place
	// on the ladder -- the last league is a place as well as a number, so it
	// stays scarce however far ratings drift.
	AtRating, TopN int
}

// Move is what one fight does to two ratings.
type Move struct {
	Attacker, Defender int // the ratings AFTER
	DeltaA, DeltaD     int // signed, for the result screen
}

// expected is the share of a fight a rating gap gives the HIGHER-rated side, in
// basis points, for gaps 0, 25, 50 ... 800. Generated from 1/(1+10^(-d/400)).
var expected = [33]int64{
	5000, 5359, 5715, 6063, 6401, 6725,
	7034, 7325, 7597, 7850, 8083, 8296,
	8490, 8666, 8823, 8965, 9091, 9203,
	9302, 9390, 9468, 9536, 9595, 9648,
	9693, 9733, 9768, 9799, 9825, 9848,
	9868, 9886, 9901,
}

// expectedStep is the rating gap between two rows of the table.
const expectedStep = 25

// expectedAhead is the table read (and interpolated) for a NON-NEGATIVE gap.
func expectedAhead(gap int) int64 {
	if gap <= 0 {
		return expected[0]
	}
	i := gap / expectedStep
	if i >= len(expected)-1 {
		return expected[len(expected)-1]
	}
	// Linear between the two rows, rounded half up.
	lo, hi := expected[i], expected[i+1]
	rem := int64(gap - i*expectedStep)
	return lo + (hi-lo)*rem/expectedStep
}

// ExpectedBP is the share of a fight A is expected to take against B, in basis
// points.
//
// Mirrored rather than computed twice, so ExpectedBP(a,b) + ExpectedBP(b,a) is
// exactly 10000 and no sequence of fights can mint a rating out of rounding.
func ExpectedBP(ratingA, ratingB int) int64 {
	if ratingA >= ratingB {
		return expectedAhead(ratingA - ratingB)
	}
	return 10000 - expectedAhead(ratingB-ratingA)
}

// Fight returns both ratings after a fight, and the signed change to each.
//
// A fight never moves nothing: the winner gains at least one point and the
// loser gives up at least one, however lopsided the gap, because a fight whose
// number did not move reads as broken. The floor and the ceiling are the only
// things that stop it.
func Fight(r Rules, attacker, defender int, attackerWon bool) Move {
	eA := ExpectedBP(attacker, defender)
	var scoreA int64
	if attackerWon {
		scoreA = 10000
	}
	diff := scoreA - eA // signed basis points

	dA := roundDiv(int64(r.K)*diff, 10000)
	dD := roundDiv(int64(r.K)*(-diff)*r.DefenderKBP, 10000*10000)
	dA = atLeastOne(dA, attackerWon)
	dD = atLeastOne(dD, !attackerWon)

	after := Move{
		Attacker: clamp(attacker+int(dA), r.Floor, r.Ceiling),
		Defender: clamp(defender+int(dD), r.Floor, r.Ceiling),
	}
	// Reported from the clamped values, so the screen's "+16" is the change the
	// stored rating actually took.
	after.DeltaA = after.Attacker - attacker
	after.DeltaD = after.Defender - defender
	return after
}

// atLeastOne keeps a move off zero, in the direction the result demands.
func atLeastOne(d int64, up bool) int64 {
	if up && d < 1 {
		return 1
	}
	if !up && d > -1 {
		return -1
	}
	return d
}

// roundDiv divides, rounding half away from zero, so a loss and a win of the
// same size move the same distance.
func roundDiv(n, d int64) int64 {
	if d == 0 {
		return 0
	}
	if n < 0 {
		return -((-n + d/2) / d)
	}
	return (n + d/2) / d
}

func clamp(v, lo, hi int) int {
	if hi > 0 && v > hi {
		return hi
	}
	if v < lo {
		return lo
	}
	return v
}

// League is the band a rating stands in. place is the lord's place on the
// ladder, 1-based, and 0 for a lord who has no place yet.
//
// The last league is a PLACE as well as a rating: a lord at 1900 ranked 51st is
// Sapphire, not Imperial. Written as one function, walked from the top down, so
// nowhere can read the rule as "or".
func League(ls []Tier, rating, place int) Tier {
	for i := len(ls) - 1; i >= 0; i-- {
		t := ls[i]
		if rating < t.AtRating {
			continue
		}
		if t.TopN > 0 && (place < 1 || place > t.TopN) {
			continue
		}
		return t
	}
	if len(ls) > 0 {
		return ls[0]
	}
	return Tier{}
}

// Next is the league above the one a rating stands in, and the rating that
// opens it. Nil at the top.
//
// Read on the rating alone: the bar on the arena's card fills toward the next
// rating, and a place the lord does not hold yet cannot be drawn as progress.
func Next(ls []Tier, rating int) (*Tier, int) {
	for i := range ls {
		if rating < ls[i].AtRating {
			t := ls[i]
			return &t, t.AtRating
		}
	}
	return nil, 0
}

// Floor is the rating the lord's current band opens at, for the card's bar.
func Floor(ls []Tier, rating int) int {
	out := 0
	for i := range ls {
		if rating >= ls[i].AtRating {
			out = ls[i].AtRating
		}
	}
	return out
}

// HalfReset is where a rating starts the next season: ResetBP of the distance
// from Start is kept, the rest given back. 1600 becomes 1300; 1000 stays; 800
// rises to 900.
func HalfReset(r Rules, rating int) int {
	moved := int64(rating-r.Start) * r.ResetBP / 10000
	return clamp(r.Start+int(moved), r.Floor, r.Ceiling)
}

// Band is the rating window opponents are drawn from, widened step times when
// the narrower window held nobody. Never inverted, never below zero.
func Band(base, widen, step, rating int) (lo, hi int) {
	if step < 0 {
		step = 0
	}
	width := base + widen*step
	if width < 1 {
		width = 1
	}
	lo, hi = rating-width, rating+width
	if lo < 0 {
		lo = 0
	}
	if hi < lo {
		hi = lo
	}
	return lo, hi
}

// MilestonesCrossed is which of a table's milestones a rating has newly
// reached, given the mask of those already paid this season, and the mask to
// store once they are paid.
func MilestonesCrossed(rating int, at []int, paid uint64) (rungs []int, mask uint64) {
	mask = paid
	for i, r := range at {
		if i >= 63 {
			break
		}
		bit := uint64(1) << uint(i)
		if rating >= r && mask&bit == 0 {
			rungs = append(rungs, i)
			mask |= bit
		}
	}
	return rungs, mask
}
