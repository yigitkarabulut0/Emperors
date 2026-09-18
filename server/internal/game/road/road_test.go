package road

import (
	"reflect"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// A lord past milestones when the road opened claims them the same; a claimed
// one is not offered again; one not reached is not offered at all.
func TestTheRoadOffersWhatIsReachedAndUnclaimed(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	ms := b.Retention.Road.Milestones
	if len(ms) != 15 {
		t.Fatalf("%d milestones, want 15", len(ms))
	}
	nodes := Build(ms, 12, Mask([]int{0, 2}))
	if got, want := Claimable(nodes), []int{1, 3, 4}; !reflect.DeepEqual(got, want) {
		t.Fatalf("claimable at level 12 with 0 and 2 claimed: %v, want %v", got, want)
	}
	if got := Claimable(Build(ms, 1, 0)); len(got) != 0 {
		t.Fatalf("a level-1 lord can claim %v", got)
	}
	all := make([]int, len(ms))
	for i := range all {
		all[i] = i
	}
	if got := Claimable(Build(ms, 60, Mask(all))); len(got) != 0 {
		t.Fatalf("everything claimed, yet %v is offered", got)
	}
	var diamonds int64
	for _, m := range ms {
		diamonds += m.Grant.Diamonds
	}
	if diamonds != 435 {
		t.Fatalf("the road pays %d diamonds, want 435", diamonds)
	}
}
