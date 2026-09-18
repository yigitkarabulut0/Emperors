// Package cart is the Tax Cart's arithmetic: when carts arrive, how many can
// wait, and which prize a cart holds.
//
// Pure: the service reads and writes the player row; time arrives as an
// argument.
package cart

import (
	"math/rand/v2"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Yard is the carts at a lord's gate: Stock waiting, and the clock the next
// one is counted from. While the yard is full the clock waits, and a cart
// taken from a full yard starts it again.
type Yard struct {
	Stock int
	At    time.Time
}

// Settle is the yard as it stands at now: every cart that has arrived since
// At, up to cap.
//
// Whole intervals only, so At moves by exactly what arrived and the part of an
// interval already served carries over. A yard that fills stops its clock at
// now: nothing arrives while it is full, and the next cart is counted from the
// moment one is taken.
func Settle(y Yard, capacity int, interval time.Duration, now time.Time) Yard {
	if interval <= 0 {
		return y
	}
	if y.Stock >= capacity {
		return Yard{Stock: y.Stock, At: later(y.At, now)}
	}
	elapsed := now.Sub(y.At)
	if elapsed < 0 {
		return y
	}
	n := int(elapsed / interval)
	if y.Stock+n >= capacity {
		return Yard{Stock: capacity, At: now}
	}
	return Yard{Stock: y.Stock + n, At: y.At.Add(time.Duration(n) * interval)}
}

// NextIn is how long until the next cart arrives at a settled yard, and zero
// while it is full (nothing is on the road).
func NextIn(y Yard, capacity int, interval time.Duration, now time.Time) time.Duration {
	if y.Stock >= capacity || interval <= 0 {
		return 0
	}
	left := y.At.Add(interval).Sub(now)
	if left < 0 {
		return 0
	}
	return left
}

// Take opens one waiting cart from a settled yard. From a full yard the clock
// starts now; otherwise it runs on as it was.
func Take(y Yard, capacity int, now time.Time) (Yard, bool) {
	if y.Stock <= 0 {
		return y, false
	}
	next := Yard{Stock: y.Stock - 1, At: y.At}
	if y.Stock >= capacity {
		next.At = now
	}
	return next, true
}

// Draw picks one row of the published odds with rng, in proportion to their
// basis points. The same rng draws the same prize: the service seeds it with
// the lord and the cart's number, so a cart's prize is fixed before it opens.
func Draw(rng *rand.Rand, odds []gameconfig.CartPrize) int {
	var total int64
	for _, o := range odds {
		total += o.BP
	}
	if total <= 0 {
		return 0
	}
	r := rng.Int64N(total)
	for i, o := range odds {
		if r < o.BP {
			return i
		}
		r -= o.BP
	}
	return len(odds) - 1
}

func later(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}
