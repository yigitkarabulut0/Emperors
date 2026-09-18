// Package road is the Victory Road: fifteen milestones on the way to the level
// cap, each claimed once, any time after it is reached.
//
// Pure: the claimed milestones arrive as a bitmask (players.road_claimed).
package road

import "github.com/yigitkarabulut0/emperors/server/internal/gameconfig"

// Node is one milestone as a lord stands to it.
type Node struct {
	Index   int
	Level   int
	Crown   bool
	Reached bool
	Claimed bool
}

// Build lays the road out for a lord at level with these milestones claimed.
func Build(ms []gameconfig.RoadMilestone, level int, claimed uint32) []Node {
	out := make([]Node, len(ms))
	for i, m := range ms {
		out[i] = Node{
			Index: i, Level: m.Level, Crown: m.Crown,
			Reached: level >= m.Level,
			Claimed: claimed&(1<<uint(i)) != 0,
		}
	}
	return out
}

// Claimable is every milestone reached and not yet claimed, in order.
func Claimable(nodes []Node) []int {
	var out []int
	for _, n := range nodes {
		if n.Reached && !n.Claimed {
			out = append(out, n.Index)
		}
	}
	return out
}

// Mask is the bit for these milestones.
func Mask(indexes []int) uint32 {
	var m uint32
	for _, i := range indexes {
		m |= 1 << uint(i)
	}
	return m
}
