// Package adminstream pushes live events to the admin panel over a websocket.
//
// The rule it follows is the one docs/design/admin.md §15 wrote down: stream
// only what another actor changed, and poll everything you are merely watching.
// So presence, other admins' writes, boosts and the audit trail are pushed;
// analytics series, ledgers and battle history are fetched.
package adminstream

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

// Frame is one message. Every frame carries a sequence number so a panel can
// tell it has missed something rather than quietly diverge from the truth.
type Frame struct {
	T    string          `json:"t"`
	Seq  uint64          `json:"seq"`
	At   int64           `json:"at"` // unix millis, server clock
	Data json.RawMessage `json:"data,omitempty"`
}

// Snapshotter builds the payload for the hello frame: everything the panel
// needs to render before a single event arrives.
type Snapshotter func(ctx context.Context) (any, error)

// Hub fans events out to every connected panel.
type Hub struct {
	mu   sync.RWMutex
	subs map[*sub]struct{}

	seq   atomic.Uint64
	epoch string
	now   func() time.Time
	log   *slog.Logger

	snapshot Snapshotter
}

// sub is one connected panel.
type sub struct {
	// out is buffered. A panel that cannot keep up is dropped rather than
	// allowed to block the broadcaster -- see send.
	out  chan []byte
	done chan struct{}
	once sync.Once
}

func (s *sub) close() { s.once.Do(func() { close(s.done) }) }

// New builds a hub. epoch changes on every restart, which is how a panel knows
// its view of the world is from a previous life of the process.
func New(now func() time.Time, log *slog.Logger, snapshot Snapshotter) *Hub {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Hub{
		subs:     make(map[*sub]struct{}),
		epoch:    uuid.NewString(),
		now:      now,
		log:      log,
		snapshot: snapshot,
	}
}

// Epoch identifies this run of the process.
func (h *Hub) Epoch() string { return h.epoch }

// Subscribers reports how many panels are connected.
func (h *Hub) Subscribers() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

// bufferedFrames is how far behind a panel may fall before it is dropped.
//
// Sized for a burst, not a backlog: a hundred players logging in at once is
// about this many frames, and anything beyond it means the socket is not
// draining. Dropping is the right answer -- the panel reconnects and gets a
// fresh snapshot, which is both correct and cheaper than replaying a queue.
const bufferedFrames = 128

func (h *Hub) subscribe() *sub {
	s := &sub{out: make(chan []byte, bufferedFrames), done: make(chan struct{})}
	h.mu.Lock()
	h.subs[s] = struct{}{}
	h.mu.Unlock()
	return s
}

func (h *Hub) unsubscribe(s *sub) {
	h.mu.Lock()
	delete(h.subs, s)
	h.mu.Unlock()
	s.close()
}

// Publish encodes an event once and hands it to every subscriber.
//
// The classic way to get this wrong is to write to each socket from the
// broadcaster: one panel on a stalled connection then blocks every other panel,
// and eventually the game handler that called Publish. So each subscriber owns
// a buffered channel and its own writer goroutine, and a send that would block
// drops that subscriber instead of waiting.
func (h *Hub) Publish(kind string, payload any) {
	h.mu.RLock()
	n := len(h.subs)
	h.mu.RUnlock()
	if n == 0 {
		// Nobody is watching. Do not pay for the JSON.
		h.seq.Add(1)
		return
	}

	var raw json.RawMessage
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			h.log.Error("could not encode stream event", "kind", kind, "err", err)
			return
		}
		raw = b
	}
	frame := Frame{T: kind, Seq: h.seq.Add(1), At: h.now().UnixMilli(), Data: raw}
	b, err := json.Marshal(frame)
	if err != nil {
		h.log.Error("could not encode stream frame", "kind", kind, "err", err)
		return
	}

	var slow []*sub
	h.mu.RLock()
	for s := range h.subs {
		select {
		case s.out <- b:
		default:
			slow = append(slow, s)
		}
	}
	h.mu.RUnlock()

	for _, s := range slow {
		h.log.Warn("dropping an admin panel that stopped reading", "kind", kind)
		h.unsubscribe(s)
	}
}

// hello is the first frame on every connection: the whole world, so the panel
// renders complete before any event arrives.
type hello struct {
	Protocol int    `json:"protocol"`
	Epoch    string `json:"epoch"`
	Me       any    `json:"me"`
	Snapshot any    `json:"snapshot"`
}

// Protocol is bumped when a frame shape changes incompatibly. The panel refuses
// to run against a version it does not know rather than mis-rendering it.
const Protocol = 1

func (h *Hub) helloFrame(ctx context.Context, me any) ([]byte, error) {
	var snap any
	if h.snapshot != nil {
		s, err := h.snapshot(ctx)
		if err != nil {
			return nil, err
		}
		snap = s
	}
	payload, err := json.Marshal(hello{Protocol: Protocol, Epoch: h.epoch, Me: me, Snapshot: snap})
	if err != nil {
		return nil, err
	}
	return json.Marshal(Frame{
		T: "hello", Seq: h.seq.Add(1), At: h.now().UnixMilli(), Data: payload,
	})
}

// Close disconnects every panel with a reason.
//
// Called before the admin server shuts down, because http.Server.Shutdown does
// not close hijacked connections and does not wait for them -- so without this
// a deploy leaves every open panel believing it is still connected to a process
// that has gone.
func (h *Hub) Close(reason string) {
	h.mu.Lock()
	subs := make([]*sub, 0, len(h.subs))
	for s := range h.subs {
		subs = append(subs, s)
	}
	h.subs = make(map[*sub]struct{})
	h.mu.Unlock()

	for _, s := range subs {
		s.close()
	}
	if len(subs) > 0 {
		h.log.Info("closed admin streams", "panels", len(subs), "reason", reason)
	}
}
