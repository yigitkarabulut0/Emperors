package realtime

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
)

func testHub() *Hub {
	return New(func() time.Time { return time.Unix(0, 0) }, nil)
}

// The rule that makes rooms worth having: a line said in one kingdom must never
// reach another. Everything else here is the panel's stream with a key on it.
func TestAFrameNeverLeavesItsRoom(t *testing.T) {
	h := testHub()
	vale, marches := uuid.New(), uuid.New()
	inVale := h.subscribe(vale)
	inMarches := h.subscribe(marches)

	h.Publish(vale, KindChat, map[string]string{"body": "the pass is held"})

	select {
	case b := <-inVale.out:
		var f Frame
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatal(err)
		}
		if f.T != KindChat {
			t.Errorf("the Vale heard a %q", f.T)
		}
	default:
		t.Fatal("the Vale heard nothing said in the Vale")
	}
	select {
	case b := <-inMarches.out:
		t.Fatalf("the Marches heard the Vale: %s", b)
	default:
	}
}

// The failure this design exists to prevent: one lord who has stopped reading
// must not be able to hold up the hall, or the action that wrote to it.
func TestASlowLordIsDroppedAndNeverBlocksTheHall(t *testing.T) {
	h := testHub()
	room := uuid.New()
	stuck := h.subscribe(room)
	healthy := h.subscribe(room)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range bufferedFrames * 3 {
			h.Publish(room, KindChat, map[string]int{"n": i})
			// The healthy lord drains as it goes, the way a real socket writer
			// does.
			select {
			case <-healthy.out:
			default:
			}
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a lord who stopped reading -- the whole point of the buffer is that it cannot")
	}
	select {
	case <-stuck.done:
	default:
		t.Error("the stuck lord was not dropped")
	}
	if got := h.Listeners(room); got != 1 {
		t.Errorf("listeners = %d, want 1 (the healthy one survives)", got)
	}
}

// An empty room is forgotten: a realm of ten thousand kingdoms must not carry
// ten thousand empty maps for the life of the process.
func TestAnEmptyRoomIsForgotten(t *testing.T) {
	h := testHub()
	room := uuid.New()
	s := h.subscribe(room)
	if h.Connected() != 1 {
		t.Fatalf("connected = %d", h.Connected())
	}
	h.unsubscribe(s)
	if h.Connected() != 0 {
		t.Errorf("connected = %d after the last lord left", h.Connected())
	}
	h.mu.RLock()
	rooms := len(h.rooms)
	h.mu.RUnlock()
	if rooms != 0 {
		t.Errorf("%d rooms are still held", rooms)
	}
}

// Publishing into a room nobody is in must cost nothing and must not panic:
// most halls are empty most of the time.
func TestPublishingIntoAnEmptyRoomIsFree(t *testing.T) {
	h := testHub()
	h.Publish(uuid.New(), KindGoal, map[string]int{"progress": 5})
	if h.Connected() != 0 {
		t.Errorf("connected = %d", h.Connected())
	}
}

func TestSequenceNumbersAreOrderedWithinARoom(t *testing.T) {
	h := testHub()
	room := uuid.New()
	s := h.subscribe(room)
	for range 5 {
		h.Publish(room, KindChat, nil)
	}
	last := uint64(0)
	for range 5 {
		var f Frame
		if err := json.Unmarshal(<-s.out, &f); err != nil {
			t.Fatal(err)
		}
		if f.Seq <= last {
			t.Fatalf("seq went %d then %d", last, f.Seq)
		}
		last = f.Seq
	}
}

// Every lord is disconnected when the process goes, or a deploy leaves open
// halls talking to a server that has gone.
func TestCloseEmptiesEveryRoom(t *testing.T) {
	h := testHub()
	a, b := h.subscribe(uuid.New()), h.subscribe(uuid.New())
	h.Close("shutting down")
	for i, s := range []*sub{a, b} {
		select {
		case <-s.done:
		default:
			t.Errorf("lord %d was left connected", i)
		}
	}
	if h.Connected() != 0 {
		t.Errorf("connected = %d after Close", h.Connected())
	}
}
