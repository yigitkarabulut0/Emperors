package adminstream

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func testHub(snap any) *Hub {
	return New(func() time.Time { return time.Unix(0, 0) }, nil,
		func(context.Context) (any, error) { return snap, nil })
}

// The failure this design exists to prevent: one panel that has stopped reading
// must not be able to hold up the game.
func TestASlowPanelIsDroppedAndNeverBlocksThePublisher(t *testing.T) {
	h := testHub(nil)
	stuck := h.subscribe()
	healthy := h.subscribe()

	done := make(chan struct{})
	go func() {
		defer close(done)
		// Far more than the buffer, and nothing is draining `stuck`.
		for i := 0; i < bufferedFrames*3; i++ {
			h.Publish("presence.counts", map[string]int{"playing": i})
			// The healthy subscriber drains as it goes, the way a real socket
			// writer does.
			select {
			case <-healthy.out:
			default:
			}
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a subscriber that stopped reading — the whole point of the buffer is that it cannot")
	}

	select {
	case <-stuck.done:
	default:
		t.Error("the stuck subscriber was not dropped")
	}
	if h.Subscribers() != 1 {
		t.Errorf("subscribers = %d, want 1 (the healthy one survives)", h.Subscribers())
	}
}

func TestSequenceNumbersAreDenseAndOrdered(t *testing.T) {
	h := testHub(nil)
	s := h.subscribe()

	for i := 0; i < 10; i++ {
		h.Publish("tick", map[string]int{"n": i})
	}

	var last uint64
	for i := 0; i < 10; i++ {
		var f Frame
		if err := json.Unmarshal(<-s.out, &f); err != nil {
			t.Fatal(err)
		}
		if i > 0 && f.Seq != last+1 {
			t.Fatalf("frame %d has seq %d after %d — a gap the panel cannot tell from a lost frame", i, f.Seq, last)
		}
		last = f.Seq
	}
}

// With nobody watching, the hub must not pay to encode events. The sequence
// still advances so a panel connecting later cannot mistake the quiet period
// for a gap.
func TestPublishingToNobodyIsCheapButStillCounts(t *testing.T) {
	h := testHub(nil)
	before := h.seq.Load()
	h.Publish("tick", map[string]int{"n": 1})
	if h.seq.Load() != before+1 {
		t.Error("the sequence did not advance with no subscribers")
	}
}

func TestCloseDisconnectsEveryoneAndIsIdempotent(t *testing.T) {
	h := testHub(nil)
	a, b := h.subscribe(), h.subscribe()

	h.Close("test")
	h.Close("test again")

	for i, s := range []*sub{a, b} {
		select {
		case <-s.done:
		default:
			t.Errorf("subscriber %d was not closed", i)
		}
	}
	if h.Subscribers() != 0 {
		t.Errorf("subscribers = %d after Close, want 0", h.Subscribers())
	}
}

// End to end over a real socket, including the deadline bug that would
// otherwise kill every connection at exactly WriteTimeout.
func TestServeOverARealSocket(t *testing.T) {
	h := testHub(map[string]any{"playing": 3})

	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.Serve(w, r, map[string]any{"username": "yigit", "role": "owner"}, []string{"*"})
	}))
	// A deliberately brutal write timeout, set before the server starts.
	//
	// Without the handler clearing the connection's deadlines before upgrading,
	// the socket dies a second in and this test fails -- which is exactly the
	// regression worth pinning, because in production the symptom is "the panel
	// reconnects every sixty seconds" and the cause is three lines away in a
	// different file.
	srv.Config.WriteTimeout = time.Second
	srv.Config.ReadTimeout = time.Second
	srv.Start()
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, "ws"+srv.URL[len("http"):], nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	// The first frame is always the whole world.
	_, b, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var f Frame
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if f.T != "hello" {
		t.Fatalf("first frame is %q, want hello", f.T)
	}
	var hi struct {
		Protocol int            `json:"protocol"`
		Epoch    string         `json:"epoch"`
		Me       map[string]any `json:"me"`
		Snapshot map[string]any `json:"snapshot"`
	}
	if err := json.Unmarshal(f.Data, &hi); err != nil {
		t.Fatal(err)
	}
	if hi.Protocol != Protocol || hi.Epoch == "" {
		t.Errorf("hello = %+v, want protocol %d and an epoch", hi, Protocol)
	}
	if hi.Me["role"] != "owner" {
		t.Errorf("hello identity = %v, want the owner it was served for", hi.Me)
	}
	if hi.Snapshot["playing"] != float64(3) {
		t.Errorf("hello snapshot = %v, want the board", hi.Snapshot)
	}

	// Wait past the server's one-second write timeout, then prove the socket is
	// still alive and carrying events.
	time.Sleep(1500 * time.Millisecond)

	// Give Serve a moment to have subscribed, then publish.
	deadline := time.Now().Add(2 * time.Second)
	for h.Subscribers() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	h.Publish("presence.joined", map[string]any{"players": []string{"kaan"}})

	_, b, err = conn.Read(ctx)
	if err != nil {
		t.Fatalf("the socket died after the server's write timeout elapsed: %v", err)
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if f.T != "presence.joined" {
		t.Errorf("second frame is %q, want presence.joined", f.T)
	}
}

func TestConcurrentPublishIsSafe(t *testing.T) {
	h := testHub(nil)
	for i := 0; i < 5; i++ {
		s := h.subscribe()
		go func() {
			for range s.out {
			}
		}()
	}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			h.Publish("tick", map[string]int{"n": i})
		}(i)
	}
	wg.Wait()
}
