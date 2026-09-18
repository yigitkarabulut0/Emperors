package social

import "time"

// ChatRules is what the hall allows, from social.json.
type ChatRules struct {
	Burst         int
	RefillSeconds int
	WindowMinutes int
	WindowMax     int
	MaxChars      int
}

// SpeakRefusal is why a line was not said. The empty string means it may be.
type SpeakRefusal string

const (
	// RefusalSilence: the bucket is empty -- said too fast.
	RefusalSilence SpeakRefusal = "too_fast"
	// RefusalWindow: the window is full -- said too much.
	RefusalWindow SpeakRefusal = "too_much"
	// RefusalLong: past max_chars.
	RefusalLong SpeakRefusal = "too_long"
	// RefusalEmpty: nothing but spaces.
	RefusalEmpty SpeakRefusal = "empty"
)

// MaySpeak answers whether a line may be said now, given when the lord last
// spoke and how many lines they have said inside the window.
//
// Two leashes, and both must pass. The BUCKET is the fast one: Burst lines
// ready, one back every RefillSeconds, so a lord can answer three people at
// once and then has to breathe. The WINDOW is the slow one: never more than
// WindowMax in WindowMinutes, whatever the bucket says -- which is what stops
// a lord who waits two minutes and then empties a full bucket into the hall.
//
// Both are reconstructed from what is already in the database -- the lord's
// own lines -- rather than kept in memory: a server restart must not hand
// everybody a fresh bucket, and two servers must not each keep their own.
//
// chars is the line's length in RUNES. A line is bytes on the wire and
// characters to a person, and 240 bytes of Turkish is 150 characters.
func MaySpeak(r ChatRules, chars int, lastAt time.Time, saidInWindow int, now time.Time) SpeakRefusal {
	if chars <= 0 {
		return RefusalEmpty
	}
	if r.MaxChars > 0 && chars > r.MaxChars {
		return RefusalLong
	}
	if r.WindowMax > 0 && saidInWindow >= r.WindowMax {
		return RefusalWindow
	}
	// Inside the burst, every line goes: that allowance is exactly what
	// answering three people at once needs. Past it, one line every
	// RefillSeconds until the window itself runs out.
	if saidInWindow >= r.Burst && r.RefillSeconds > 0 && !lastAt.IsZero() {
		if now.Sub(lastAt) < time.Duration(r.RefillSeconds)*time.Second {
			return RefusalSilence
		}
	}
	return ""
}

// NextLineAt is when the hall will take another line, for the client's own
// countdown. Zero means now.
func NextLineAt(r ChatRules, lastAt time.Time, saidInWindow int, windowStart time.Time) time.Time {
	if r.WindowMax > 0 && saidInWindow >= r.WindowMax {
		return windowStart.Add(time.Duration(r.WindowMinutes) * time.Minute)
	}
	if saidInWindow >= r.Burst && r.RefillSeconds > 0 && !lastAt.IsZero() {
		return lastAt.Add(time.Duration(r.RefillSeconds) * time.Second)
	}
	return time.Time{}
}

// StrikesThatMute reports whether this strike is the one that shuts the hall,
// and until when.
func StrikesThatMute(strikes, strikesToMute, muteMinutes int, now time.Time) (bool, time.Time) {
	if strikesToMute <= 0 || strikes < strikesToMute {
		return false, time.Time{}
	}
	return true, now.Add(time.Duration(muteMinutes) * time.Minute)
}

// -------------------------------------------------------------- the gift
//
// What a gift is worth has no arithmetic of its own: a gift is a FLASK, and a
// flask is a share of the taker's own pool, worked out where every other flask
// is (service.flaskAmount). The only rule here is how many a day, and that is
// a count the database enforces in the statement that spends one.

// --------------------------------------------------------------- the aid

// AidStacks is how many stacks a lord may still take: the cap, less what they
// are holding.
func AidStacks(holding, max int) int {
	if holding >= max {
		return 0
	}
	return max - holding
}

// -------------------------------------------------------------- the goal

// GoalTarget is the bar a kingdom of this many members is set: what one member
// is expected to add, times the members it had when the goal was set.
//
// Frozen at the moment the goal is made. A kingdom that doubles overnight does
// not double its bar, and one that empties does not keep a bar nobody can
// reach.
func GoalTarget(perMember int64, members int) int64 {
	if members < 1 {
		members = 1
	}
	return perMember * int64(members)
}

// GoalShare is the least a lord must have put in to claim a chest: a share of
// an EQUAL share, so a kingdom cannot be carried by one lord and claimed by
// thirty.
//
// Always at least 1: a goal somebody watched from a chair pays them nothing.
func GoalShare(target int64, members int, shareOfEqualBP int64) int64 {
	if members < 1 {
		members = 1
	}
	equal := target / int64(members)
	need := equal * shareOfEqualBP / 10000
	if need < 1 {
		need = 1
	}
	return need
}

// GoalTiersReached is a bit per chest the bar has reached, given the tiers'
// thresholds in basis points of the target.
func GoalTiersReached(progress, target int64, atBP []int64) int {
	if target <= 0 {
		return 0
	}
	bits := 0
	bp := progress * 10000 / target
	for i, at := range atBP {
		if bp >= at {
			bits |= 1 << i
		}
	}
	return bits
}
