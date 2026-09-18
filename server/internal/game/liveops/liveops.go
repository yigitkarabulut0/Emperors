// Package liveops is the realm calendar's arithmetic: which event an hour
// rolls, which season a moment falls in, and how points accrue under a daily
// cap.
//
// Pure: time and the server's secret arrive as arguments.
package liveops

import (
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/game"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Hour is an hour as a whole number: Unix hours, so every server agrees.
func Hour(t time.Time) int64 { return t.Unix() / 3600 }

// HourStart is the instant an hour begins.
func HourStart(h int64) time.Time { return time.Unix(h*3600, 0).UTC() }

// roll draws one row of the table for an hour, the draw-th time.
func roll(secret []byte, hour int64, draw uint64, table []gameconfig.HourlyEvent) string {
	var total int64
	for _, e := range table {
		total += e.BP
	}
	if total <= 0 {
		return gameconfig.HourlyNone
	}
	r := game.SeedForString(secret, "hourly", uint64(hour), draw).Int64N(total)
	for _, e := range table {
		if r < e.BP {
			return e.ID
		}
		r -= e.BP
	}
	return table[len(table)-1].ID
}

// Lookback is how many hours the no-repeat chain starts before the asked one:
// far enough that the chain's first link (which cannot see its own
// predecessor) no longer decides anything. A caller holding written-down hours
// holds this many before the one it asks about.
const Lookback = 24

// HourlyAt is the event the hour rolls: a keyed hash of the hour, overridden
// by the panel where it says so, and -- with no_repeat -- never the event of
// the hour before (an hour that would repeat draws again). "none" may run
// twice. The chain is walked from lookback hours back, so every server and
// every lord agree on every hour.
func HourlyAt(secret []byte, cfg gameconfig.HourlyConfig, overrides map[int64]string, hour int64) string {
	prev := ""
	var id string
	for h := hour - Lookback; h <= hour; h++ {
		id = pick(secret, cfg, overrides, h, prev)
		prev = id
	}
	return id
}

func pick(secret []byte, cfg gameconfig.HourlyConfig, overrides map[int64]string, h int64, prev string) string {
	if o, ok := overrides[h]; ok {
		return o
	}
	for draw := uint64(0); draw < 8; draw++ {
		id := roll(secret, h, draw, cfg.Table)
		if !cfg.NoRepeat || id == gameconfig.HourlyNone || id != prev {
			return id
		}
	}
	return gameconfig.HourlyNone
}

// Season is a season's number and its window. Number 0 is before the first.
type Season struct {
	Number int
	Start  time.Time
	End    time.Time
}

// SeasonAt is the season a moment falls in.
func SeasonAt(cfg gameconfig.SeasonConfig, t time.Time) Season {
	epoch, err := time.Parse("2006-01-02", cfg.Epoch)
	if err != nil || cfg.Days <= 0 {
		return Season{}
	}
	span := time.Duration(cfg.Days) * 24 * time.Hour
	if t.Before(epoch) {
		return Season{Number: 0, Start: epoch.Add(-span), End: epoch}
	}
	n := int(t.Sub(epoch) / span)
	start := epoch.Add(time.Duration(n) * span)
	return Season{Number: n + 1, Start: start, End: start.Add(span)}
}

// SeasonNumbered is season n's window.
func SeasonNumbered(cfg gameconfig.SeasonConfig, n int) Season {
	epoch, _ := time.Parse("2006-01-02", cfg.Epoch)
	span := time.Duration(cfg.Days) * 24 * time.Hour
	start := epoch.Add(time.Duration(n-1) * span)
	return Season{Number: n, Start: start, End: start.Add(span)}
}

// PointsMilli is what one action's deeds earn, in thousandths of a point, so
// "a point for every five energy" keeps its fractions across actions.
func PointsMilli(sources []gameconfig.PointSource, deeds map[string]int64) int64 {
	var milli int64
	for _, s := range sources {
		if n := deeds[s.Deed]; n > 0 && s.Per > 0 {
			milli += n * s.Points * 1000 / s.Per
		}
	}
	return milli
}

// Tier is the tier a season's points reach, 0..tiers.
func Tier(points, perTier int64, tiers int) int {
	if perTier <= 0 {
		return 0
	}
	t := int(points / perTier)
	if t > tiers {
		return tiers
	}
	return t
}

// DayOf is which day of a run an instant falls on, from 1: a festival's days
// and a season's are counted from their own start, the same for every lord, so
// a daily cap is the same cap for all of them. Before the start is day 0.
func DayOf(start, now time.Time) int {
	if now.Before(start) {
		return 0
	}
	return int(now.Sub(start)/(24*time.Hour)) + 1
}

// Reached is how many of a ladder's rungs a count has reached: the tiers of a
// deed, the milestones of a festival.
func Reached(rungs []int64, n int64) int {
	k := 0
	for _, r := range rungs {
		if n < r {
			break
		}
		k++
	}
	return k
}

// Open lists what can be claimed: the first `reached` rungs whose bit is not
// set in claimed.
func Open(reached int, claimed uint64) []int {
	var out []int
	for i := 0; i < reached && i < 64; i++ {
		if claimed&(1<<uint(i)) == 0 {
			out = append(out, i)
		}
	}
	return out
}

// Mask is the bits of a set of rungs.
func Mask(rungs []int) uint64 {
	var m uint64
	for _, i := range rungs {
		m |= 1 << uint(i)
	}
	return m
}

// PlaceReward is what a place on a board pays: the first row whose Top the
// place is within (rows run from the top place down). Nil past the last row.
func PlaceReward(ranks []gameconfig.RankReward, place int) *gameconfig.RewardBundle {
	if place < 1 {
		return nil
	}
	for i := range ranks {
		if place <= ranks[i].Top {
			return &ranks[i].Grant
		}
	}
	return nil
}

// Standing is a lord's place on the season's renown, and their Charter's tier.
type Standing struct {
	Key   string
	Place int
	Tier  int
}

// Nobility names the season's nobles from its renown board: every lord who
// earned renown, in place order. Each lord is given the highest rank they
// qualify for, and ranks are read in the order the balance lists them
// (Emperor first): by place (Top), by share of those with renown (TopPct,
// rounded up so even a small season has its Count), or by the Charter's tier.
func Nobility(ranks []gameconfig.NobilityRank, board []Standing) map[string]string {
	out := map[string]string{}
	n := len(board)
	for _, s := range board {
		for _, r := range ranks {
			ok := false
			switch {
			case r.Top > 0:
				ok = s.Place <= r.Top
			case r.TopPct > 0:
				ok = s.Place <= (n*r.TopPct+99)/100
			case r.CharterTier > 0:
				ok = s.Tier >= r.CharterTier
			}
			if ok {
				out[s.Key] = r.ID
				break
			}
		}
	}
	return out
}
