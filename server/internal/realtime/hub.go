// Package realtime pushes the kingdom's own news to the lords standing in it:
// a line said in the hall, a call for aid, the shared goal's bar moving.
//
// It follows internal/adminstream, which does the same for the panel, with one
// difference that shapes everything here: this hub has ROOMS. A frame belongs
// to one kingdom and must never reach another, so a subscriber joins a room and
// a publish names one.
//
// The rule it keeps is the one the panel's stream keeps: push only what another
// actor changed, and poll everything you are merely watching. A lord's own gold,
// energy and quests arrive in the answers to their own taps; what cannot arrive
// that way is what somebody ELSE did in the same room, and that is all this
// carries.
//
// One process. The game runs as a single container on one host, as the panel's
// stream already assumes; a second instance would need a fan-out between them
// (Postgres LISTEN/NOTIFY is the obvious one) and the client's polling fallback
// is what covers the gap until then.
package realtime

import (
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

// Frame is one message. Every frame carries a sequence number so a client can
// tell it has missed something rather than quietly diverge from the truth.
type Frame struct {
	T    string          `json:"t"`
	Seq  uint64          `json:"seq"`
	At   int64           `json:"at"` // unix millis, server clock
	Data json.RawMessage `json:"data,omitempty"`
}

// The frames this hub carries. Each is a statement of what a thing NOW IS, so a
// client that missed one and takes a fresh read is never wrong for long.
const (
	// A line was said in the hall (or a system line was written).
	KindChat = "chat"
	// A line was hidden: three lords reported it, or the crown took it down.
	KindChatHidden = "chat_hidden"
	// Somebody in the kingdom asked for aid, or answered a call.
	KindAid = "aid"
	// The shared goal's bar moved.
	KindGoal = "goal"
)

// Hub fans frames out to the lords in each room.
type Hub struct {
	mu    sync.RWMutex
	rooms map[uuid.UUID]map[*sub]struct{}

	seq   atomic.Uint64
	epoch string
	now   func() time.Time
	log   *slog.Logger
}

// sub is one connected lord.
type sub struct {
	room uuid.UUID
	// out is buffered. A client that cannot keep up is dropped rather than
	// allowed to block the publisher -- see Publish.
	out  chan []byte
	done chan struct{}
	once sync.Once
}

func (s *sub) close() { s.once.Do(func() { close(s.done) }) }

// New builds a hub. epoch changes on every restart, which is how a client knows
// its view of a room is from a previous life of the process.
func New(now func() time.Time, log *slog.Logger) *Hub {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Hub{
		rooms: make(map[uuid.UUID]map[*sub]struct{}),
		epoch: uuid.NewString(),
		now:   now,
		log:   log,
	}
}

// Epoch identifies this run of the process.
func (h *Hub) Epoch() string { return h.epoch }

// Listeners reports how many lords are connected to one room.
func (h *Hub) Listeners(room uuid.UUID) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.rooms[room])
}

// Connected reports how many lords are connected in all -- what the panel's
// live page shows.
func (h *Hub) Connected() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	n := 0
	for _, r := range h.rooms {
		n += len(r)
	}
	return n
}

// bufferedFrames is how far behind a client may fall before it is dropped.
//
// Sized for a burst, not a backlog: a hall at its busiest is a few frames a
// second, and anything past this means the socket is not draining. Dropping is
// the right answer -- the client reconnects and re-reads the room, which is
// both correct and cheaper than replaying a queue.
const bufferedFrames = 64

func (h *Hub) subscribe(room uuid.UUID) *sub {
	s := &sub{room: room, out: make(chan []byte, bufferedFrames), done: make(chan struct{})}
	h.mu.Lock()
	if h.rooms[room] == nil {
		h.rooms[room] = make(map[*sub]struct{})
	}
	h.rooms[room][s] = struct{}{}
	h.mu.Unlock()
	return s
}

func (h *Hub) unsubscribe(s *sub) {
	h.mu.Lock()
	if r := h.rooms[s.room]; r != nil {
		delete(r, s)
		if len(r) == 0 {
			// An empty room is deleted: a realm of ten thousand kingdoms must
			// not carry ten thousand empty maps for the life of the process.
			delete(h.rooms, s.room)
		}
	}
	h.mu.Unlock()
	s.close()
}

// Publish encodes a frame once and hands it to everyone in that room.
//
// The classic way to get this wrong is to write to each socket from the caller:
// one lord on a stalled connection then blocks every other lord, and eventually
// the handler that said the line. So each subscriber owns a buffered channel,
// and a send that would block drops that subscriber instead of waiting.
//
// It never returns an error: the hall is not the truth, the database is. A
// frame that could not be sent costs a client one poll, and a send that failed
// must never fail the action that caused it.
func (h *Hub) Publish(room uuid.UUID, kind string, payload any) {
	h.mu.RLock()
	n := len(h.rooms[room])
	h.mu.RUnlock()
	if n == 0 {
		// Nobody is in the room. Do not pay for the JSON.
		h.seq.Add(1)
		return
	}

	var raw json.RawMessage
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			h.log.Error("could not encode a realtime event", "kind", kind, "err", err)
			return
		}
		raw = b
	}
	b, err := json.Marshal(Frame{T: kind, Seq: h.seq.Add(1), At: h.now().UnixMilli(), Data: raw})
	if err != nil {
		h.log.Error("could not encode a realtime frame", "kind", kind, "err", err)
		return
	}

	var slow []*sub
	h.mu.RLock()
	for s := range h.rooms[room] {
		select {
		case s.out <- b:
		default:
			slow = append(slow, s)
		}
	}
	h.mu.RUnlock()

	for _, s := range slow {
		h.log.Warn("dropping a lord who stopped reading the hall", "kind", kind)
		h.unsubscribe(s)
	}
}

// hello is the first frame on every connection.
type hello struct {
	Protocol int    `json:"protocol"`
	Epoch    string `json:"epoch"`
	Room     string `json:"room"`
	// The room's clock as it stands, so a client knows whether the history it
	// already holds is complete.
	Head int64 `json:"head"`
}

// Protocol is bumped when a frame shape changes incompatibly. A client refuses
// to run against a version it does not know rather than mis-rendering it.
const Protocol = 1

func (h *Hub) helloFrame(room uuid.UUID, head int64) ([]byte, error) {
	payload, err := json.Marshal(hello{Protocol: Protocol, Epoch: h.epoch, Room: room.String(), Head: head})
	if err != nil {
		return nil, err
	}
	return json.Marshal(Frame{T: "hello", Seq: h.seq.Add(1), At: h.now().UnixMilli(), Data: payload})
}

// Close disconnects every lord with a reason.
//
// Called before the game server shuts down, because http.Server.Shutdown does
// not close hijacked connections and does not wait for them -- so without this
// a deploy leaves every open hall believing it is still connected to a process
// that has gone.
func (h *Hub) Close(reason string) {
	h.mu.Lock()
	var subs []*sub
	for _, r := range h.rooms {
		for s := range r {
			subs = append(subs, s)
		}
	}
	h.rooms = make(map[uuid.UUID]map[*sub]struct{})
	h.mu.Unlock()

	for _, s := range subs {
		s.close()
	}
	if len(subs) > 0 {
		h.log.Info("closed the halls", "lords", len(subs), "reason", reason)
	}
}
