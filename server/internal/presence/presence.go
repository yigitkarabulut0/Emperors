// Package presence answers one question the admin panel could not ask before:
// who is in the game right now.
//
// It is deliberately in memory. The api process is a single replica that serves
// both listeners — the game on :8080 and the admin surface on :8081 — so a fact
// written by a player's request is readable by an admin's request with no
// database, no cache and no serialisation in between. That is also the only
// reason this is honest: presence is a statement about live connections to THIS
// process, and it is stored exactly where that statement is true.
package presence

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
)

// State is how present a player is.
type State string

const (
	// StatePlaying means we have heard from them inside PlayingWindow.
	StatePlaying State = "playing"
	// StateIdle means they were here recently but have gone quiet.
	StateIdle State = "idle"
	// StateOffline is never stored; it is the absence of an entry.
	StateOffline State = "offline"
)

const (
	// PlayingWindow is how long silence is tolerated before a player stops
	// counting as in the game.
	//
	// Three missed heartbeats at the client's 30s interval. Two would make one
	// dropped request on a train look like leaving; four would make leaving take
	// two minutes to show.
	PlayingWindow = 90 * time.Second

	// IdleWindow is how long an entry survives after it stops playing. Past this
	// the entry is evicted, which is also what bounds the map: it holds at most
	// the players seen in the last ten minutes.
	IdleWindow = 10 * time.Minute

	// SweepInterval is how often states are recomputed. It sets the worst-case
	// lag between a player going quiet and the panel saying so.
	SweepInterval = 5 * time.Second

	// FlushInterval is how often last_seen_at is written back.
	FlushInterval = 30 * time.Second

	// ReconcileWindow is how long after start-up the registry admits it does not
	// yet have a complete picture. See Seed.
	ReconcileWindow = PlayingWindow
)

// Entry is one player's presence. Not exported through the API directly — see
// View, which is the shape the panel receives.
type Entry struct {
	PlayerID uuid.UUID
	// Since is when this stretch of presence began: the moment they appeared
	// after being absent. It is what the panel shows as session length.
	Since    time.Time
	LastSeen time.Time
	// Heartbeat records that this client has ever sent an explicit heartbeat.
	//
	// It is the difference between knowing someone is in the game and inferring
	// it from the fact that they did something. Builds that predate the
	// heartbeat will never set it, and the panel must say so rather than
	// present a guess with the same confidence as a fact.
	Heartbeat bool
	// Seeded marks an entry restored from last_seen_at at start-up rather than
	// observed. See Seed.
	Seeded   bool
	Requests int64
	// Devices is the set of token families seen for this player, so two phones
	// read as two devices and one signing out does not blank the other.
	//
	// Keyed on the family and not the session row: a session is replaced on
	// every fifteen-minute refresh, so keying on it would invent a new device
	// four times an hour.
	Devices map[string]time.Time

	// state is the last state broadcast for this entry. Transitions are
	// edge-triggered off it, so the sweeper emits an event when something
	// changes rather than a full board every five seconds.
	state State
}

// View is one row of the presence board.
type View struct {
	PlayerID   uuid.UUID `json:"player_id"`
	State      State     `json:"state"`
	Since      time.Time `json:"since"`
	LastSeen   time.Time `json:"last_seen"`
	SecondsAgo int       `json:"seconds_ago"`
	Heartbeat  bool      `json:"heartbeat"`
	Inferred   bool      `json:"inferred"`
	Devices    int       `json:"devices"`
	Requests   int64     `json:"requests"`
}

// Counts is the headline: how many are in, how many are drifting out.
type Counts struct {
	Playing int `json:"playing"`
	Idle    int `json:"idle"`
	// Reconciling is true while the process is too young to know who is really
	// here. A restart empties the map, and claiming everyone left is worse than
	// admitting uncertainty for ninety seconds.
	Reconciling bool `json:"reconciling"`
}

// Sink receives presence transitions. The websocket hub implements it; a nil
// sink is valid and makes the registry silent, which is what the tests and the
// first build step use.
type Sink interface {
	PresenceJoined(v View)
	PresenceLeft(playerID uuid.UUID, reason string)
	PresenceCounts(c Counts)
}

// Registry is the live set.
//
// A plain Mutex, not the atomic.Pointer copy-on-write used by gameconfig.Store
// and service.Boosts. Those are written rarely and read constantly, so cloning
// on write is free. This is the exact opposite: a write on every authenticated
// request, and a read only when an admin looks or the sweeper runs. Copy-on-
// write would clone the whole map per request, and an RWMutex would buy nothing
// because Touch always takes the write lock.
type Registry struct {
	mu    sync.Mutex
	live  map[uuid.UUID]*Entry
	dirty map[uuid.UUID]struct{}

	now     func() time.Time
	started time.Time
	log     *slog.Logger

	sinkMu sync.RWMutex
	sink   Sink
}

// New builds an empty registry. now is injectable so the tests do not sleep.
func New(now func() time.Time, log *slog.Logger) *Registry {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Registry{
		live:    make(map[uuid.UUID]*Entry),
		dirty:   make(map[uuid.UUID]struct{}),
		now:     now,
		started: now(),
		log:     log,
	}
}

// Attach sets the sink. Separate from New because the hub needs the registry to
// build its first snapshot, so one of the two has to be wired second.
func (r *Registry) Attach(s Sink) {
	r.sinkMu.Lock()
	r.sink = s
	r.sinkMu.Unlock()
}

func (r *Registry) emit(fn func(Sink)) {
	r.sinkMu.RLock()
	s := r.sink
	r.sinkMu.RUnlock()
	if s != nil {
		fn(s)
	}
}

// Touch records that we have just heard from a player.
//
// Called from the middleware on every authenticated request, so it does the
// least work that is correct: one lock, one map lookup, three field writes.
// heartbeat says whether this was an explicit presence beat rather than an
// ordinary action.
func (r *Registry) Touch(id uuid.UUID, device string, heartbeat bool) {
	now := r.now()

	r.mu.Lock()
	e, existed := r.live[id]
	if !existed {
		e = &Entry{PlayerID: id, Since: now, Devices: make(map[string]time.Time, 1)}
		r.live[id] = e
	}
	// A seeded entry that we now hear from directly stops being a guess.
	if e.Seeded {
		e.Seeded = false
		e.Since = now
	}
	e.LastSeen = now
	e.Requests++
	if heartbeat {
		e.Heartbeat = true
	}
	if device != "" {
		e.Devices[device] = now
	}

	was := e.state
	e.state = StatePlaying
	view := e.view(now)
	r.dirty[id] = struct{}{}
	r.mu.Unlock()

	// Edge-triggered: only a change is worth a frame. A tapping player produces
	// dozens of requests a second and must not produce dozens of events.
	if was != StatePlaying {
		r.emit(func(s Sink) { s.PresenceJoined(view) })
		r.emit(func(s Sink) { s.PresenceCounts(r.Counts()) })
	}
}

// Leave removes a player immediately, on their own say-so.
//
// The client sends this when iOS backgrounds the app. It is best effort — the
// system grants a few seconds and the request may not land — which is exactly
// why PlayingWindow exists underneath it as the guarantee.
func (r *Registry) Leave(id uuid.UUID, device string) {
	r.mu.Lock()
	e, ok := r.live[id]
	if !ok {
		r.mu.Unlock()
		return
	}
	if device != "" {
		delete(e.Devices, device)
		// Another device is still holding this player in the game.
		if len(e.Devices) > 0 {
			r.mu.Unlock()
			return
		}
	}
	delete(r.live, id)
	r.dirty[id] = struct{}{}
	r.mu.Unlock()

	r.emit(func(s Sink) { s.PresenceLeft(id, "beacon") })
	r.emit(func(s Sink) { s.PresenceCounts(r.Counts()) })
}

// Sweep recomputes states, evicts what has aged out, and emits the transitions.
func (r *Registry) Sweep() {
	now := r.now()

	type change struct {
		view View
		gone bool
	}
	var changes []change

	r.mu.Lock()
	for id, e := range r.live {
		gap := now.Sub(e.LastSeen)
		switch {
		case gap > IdleWindow:
			delete(r.live, id)
			changes = append(changes, change{view: View{PlayerID: id}, gone: true})
		case gap > PlayingWindow:
			if e.state != StateIdle {
				e.state = StateIdle
				changes = append(changes, change{view: e.view(now)})
			}
		default:
			if e.state != StatePlaying {
				e.state = StatePlaying
				changes = append(changes, change{view: e.view(now)})
			}
		}
	}
	r.mu.Unlock()

	if len(changes) == 0 {
		return
	}
	for _, c := range changes {
		if c.gone {
			r.emit(func(s Sink) { s.PresenceLeft(c.view.PlayerID, "timeout") })
		} else {
			r.emit(func(s Sink) { s.PresenceJoined(c.view) })
		}
	}
	r.emit(func(s Sink) { s.PresenceCounts(r.Counts()) })
}

// Snapshot is the whole board, for the hello frame and GET /presence.
func (r *Registry) Snapshot() []View {
	now := r.now()
	r.mu.Lock()
	defer r.mu.Unlock()

	out := make([]View, 0, len(r.live))
	for _, e := range r.live {
		out = append(out, e.view(now))
	}
	return out
}

// Counts is the headline pair plus the honesty flag.
func (r *Registry) Counts() Counts {
	now := r.now()
	reconciling := now.Sub(r.started) < ReconcileWindow

	r.mu.Lock()
	defer r.mu.Unlock()

	c := Counts{Reconciling: reconciling}
	for _, e := range r.live {
		if now.Sub(e.LastSeen) > PlayingWindow {
			c.Idle++
		} else {
			c.Playing++
		}
	}
	return c
}

// State reports one player's presence without materialising the board.
func (r *Registry) State(id uuid.UUID) State {
	now := r.now()
	r.mu.Lock()
	defer r.mu.Unlock()

	e, ok := r.live[id]
	if !ok {
		return StateOffline
	}
	if now.Sub(e.LastSeen) > PlayingWindow {
		return StateIdle
	}
	return StatePlaying
}

// Seed restores entries from last_seen_at at start-up.
//
// Without this a deploy would show every player leaving at once and then
// trickling back, which is a lie about the game and a lie the panel would
// repeat to whoever is watching. Seeded entries are marked, and Counts reports
// Reconciling until the process is old enough to have heard from people itself.
func (r *Registry) Seed(rows map[uuid.UUID]time.Time) {
	now := r.now()
	r.mu.Lock()
	defer r.mu.Unlock()

	for id, seen := range rows {
		if now.Sub(seen) > IdleWindow {
			continue
		}
		if _, exists := r.live[id]; exists {
			continue
		}
		state := StatePlaying
		if now.Sub(seen) > PlayingWindow {
			state = StateIdle
		}
		r.live[id] = &Entry{
			PlayerID: id, Since: seen, LastSeen: seen,
			Seeded: true, Devices: make(map[string]time.Time),
			state: state,
		}
	}
}

// DrainDirty returns the players touched since the last call, for the
// last_seen_at write-back, and clears the set.
func (r *Registry) DrainDirty() []uuid.UUID {
	r.mu.Lock()
	defer r.mu.Unlock()

	if len(r.dirty) == 0 {
		return nil
	}
	out := make([]uuid.UUID, 0, len(r.dirty))
	for id := range r.dirty {
		out = append(out, id)
	}
	r.dirty = make(map[uuid.UUID]struct{}, len(out))
	return out
}

// Flusher writes last_seen_at back for a batch of players.
type Flusher interface {
	TouchSeen(ctx context.Context, ids []uuid.UUID) error
}

// Run sweeps and flushes until the context is cancelled.
//
// It returns rather than leaking, and main waits for it, so a shutdown does not
// drop a flush that was about to happen.
func (r *Registry) Run(ctx context.Context, f Flusher) error {
	sweep := time.NewTicker(SweepInterval)
	defer sweep.Stop()
	flush := time.NewTicker(FlushInterval)
	defer flush.Stop()

	for {
		select {
		case <-ctx.Done():
			// One last write so the final half-minute of activity is not lost.
			r.flush(context.WithoutCancel(ctx), f)
			return nil
		case <-sweep.C:
			r.Sweep()
		case <-flush.C:
			r.flush(ctx, f)
		}
	}
}

func (r *Registry) flush(ctx context.Context, f Flusher) {
	if f == nil {
		return
	}
	ids := r.DrainDirty()
	if len(ids) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := f.TouchSeen(ctx, ids); err != nil {
		r.log.Warn("could not write last_seen_at", "players", len(ids), "err", err)
	}
}

func (e *Entry) view(now time.Time) View {
	gap := now.Sub(e.LastSeen)
	state := StatePlaying
	if gap > PlayingWindow {
		state = StateIdle
	}
	return View{
		PlayerID:   e.PlayerID,
		State:      state,
		Since:      e.Since,
		LastSeen:   e.LastSeen,
		SecondsAgo: int(gap.Seconds()),
		Heartbeat:  e.Heartbeat,
		// Inferred says the panel is reading presence off ordinary game traffic
		// rather than an explicit beat, so "playing" means "acted recently" and
		// not "the app is open".
		Inferred: !e.Heartbeat,
		Devices:  len(e.Devices),
		Requests: e.Requests,
	}
}
