// Package experiments puts a lord in one arm of an A/B test, for good.
//
// Pure: the arm is a keyed hash of the test and the lord, weighted by the arms'
// weights, so the same lord is in the same arm on every server, every restart
// and every day, with no table to consult and nothing to migrate.
package experiments

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"math"
)

// Arm is one side of a test and its share of lords.
type Arm struct {
	ID     string
	Weight int
}

// Assign returns the arm a lord is in. Arms with no weight are never chosen;
// with no weight at all it returns "".
func Assign(secret []byte, test, player string, arms []Arm) string {
	total := 0
	for _, a := range arms {
		if a.Weight > 0 {
			total += a.Weight
		}
	}
	if total == 0 {
		return ""
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte("experiment:" + test + ":" + player))
	roll := int(binary.BigEndian.Uint64(mac.Sum(nil)[:8]) % uint64(total))
	for _, a := range arms {
		if a.Weight <= 0 {
			continue
		}
		if roll < a.Weight {
			return a.ID
		}
		roll -= a.Weight
	}
	return arms[len(arms)-1].ID
}

// ZScore is the two-proportion z statistic of an arm's conversion against the
// control's: positive when the arm converts better. Zero when either arm has no
// one in it, or when nobody in either converted.
func ZScore(controlN, controlConv, armN, armConv int64) float64 {
	if controlN <= 0 || armN <= 0 {
		return 0
	}
	p1 := float64(controlConv) / float64(controlN)
	p2 := float64(armConv) / float64(armN)
	pooled := float64(controlConv+armConv) / float64(controlN+armN)
	se := math.Sqrt(pooled * (1 - pooled) * (1/float64(controlN) + 1/float64(armN)))
	if se == 0 {
		return 0
	}
	return (p2 - p1) / se
}
