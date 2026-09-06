package presence

import (
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

// clock is a hand-wound time source, so the windows can be tested at their
// exact boundaries rather than by sleeping and hoping.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// recorder collects what the hub would have broadcast.
type recorder struct {
	mu     sync.Mutex
	joined []View
	left   []string
	counts []Counts
}

func (r *recorder) PresenceJoined(v View) {
	r.mu.Lock()
	r.joined = append(r.joined, v)
	r.mu.Unlock()
}

func (r *recorder) PresenceLeft(id uuid.UUID, reason string) {
	r.mu.Lock()
	r.left = append(r.left, id.String()+":"+reason)
	r.mu.Unlock()
}

func (r *recorder) PresenceCounts(c Counts) {
	r.mu.Lock()
	r.counts = append(r.counts, c)
	r.mu.Unlock()
}

func newTest() (*Registry, *clock, *recorder) {
	c := &clock{t: time.Date(2026, 9, 6, 12, 0, 0, 0, time.UTC)}
	r := New(c.now, nil)
	rec := &recorder{}
	r.Attach(rec)
	return r, c, rec
}

func TestAppearingIsImmediate(t *testing.T) {
	r, _, rec := newTest()
	id := uuid.New()

	r.Touch(id, "d1", false)

	if got := r.State(id); got != StatePlaying {
		t.Errorf("a player who just acted is %q, want %q", got, StatePlaying)
	}
	if len(rec.joined) != 1 {
		t.Fatalf("one join event expected, got %d", len(rec.joined))
	}
	if c := r.Counts(); c.Playing != 1 {
		t.Errorf("playing = %d, want 1", c.Playing)
	}
}

// A tapping player sends dozens of requests a second. That must not become
// dozens of frames on every open panel.
func TestRepeatedActivityEmitsOneEvent(t *testing.T) {
	r, c, rec := newTest()
	id := uuid.New()

	for i := 0; i < 200; i++ {
		r.Touch(id, "d1", false)
		c.add(50 * time.Millisecond)
	}

	if len(rec.joined) != 1 {
		t.Errorf("200 requests produced %d join events, want 1", len(rec.joined))
	}
}

func TestSilenceDecaysThroughIdleToGone(t *testing.T) {
	r, c, rec := newTest()
	id := uuid.New()
	r.Touch(id, "d1", false)

	// Just inside the playing window: still in the game.
	c.add(PlayingWindow - time.Second)
	r.Sweep()
	if got := r.State(id); got != StatePlaying {
		t.Errorf("at %v of silence the player is %q, want %q", PlayingWindow-time.Second, got, StatePlaying)
	}

	// Past it: idle, but still known.
	c.add(2 * time.Second)
	r.Sweep()
	if got := r.State(id); got != StateIdle {
		t.Errorf("just past the playing window the player is %q, want %q", got, StateIdle)
	}
	if c := r.Counts(); c.Idle != 1 || c.Playing != 0 {
		t.Errorf("counts = %+v, want 1 idle and 0 playing", c)
	}

	// Past the idle window: evicted entirely.
	c.add(IdleWindow)
	r.Sweep()
	if got := r.State(id); got != StateOffline {
		t.Errorf("past the idle window the player is %q, want %q", got, StateOffline)
	}
	if len(rec.left) != 1 {
		t.Fatalf("one leave event expected, got %v", rec.left)
	}
	if rec.left[0] != id.String()+":timeout" {
		t.Errorf("leave reason = %q, want timeout", rec.left[0])
	}
}

// The whole point of the heartbeat: a player who is holding the phone but not
// tapping must stay in the game.
func TestHeartbeatKeepsAnIdlePlayerPresent(t *testing.T) {
	r, c, _ := newTest()
	id := uuid.New()

	// Ten minutes of doing nothing but beating every 30 seconds.
	for i := 0; i < 20; i++ {
		r.Touch(id, "d1", true)
		c.add(30 * time.Second)
		r.Sweep()
	}

	if got := r.State(id); got != StatePlaying {
		t.Errorf("a heartbeating player is %q after 10 minutes, want %q", got, StatePlaying)
	}
	for _, v := range r.Snapshot() {
		if v.PlayerID == id && v.Inferred {
			t.Error("a heartbeating player is still marked inferred")
		}
	}
}

// A client that predates the heartbeat must be labelled, not guessed at.
func TestPreHeartbeatClientIsMarkedInferred(t *testing.T) {
	r, _, _ := newTest()
	id := uuid.New()
	r.Touch(id, "d1", false)

	snap := r.Snapshot()
	if len(snap) != 1 {
		t.Fatalf("snapshot has %d rows, want 1", len(snap))
	}
	if !snap[0].Inferred || snap[0].Heartbeat {
		t.Errorf("a client with no heartbeat reads as %+v, want inferred and not heartbeat", snap[0])
	}
}

func TestBeaconRemovesImmediately(t *testing.T) {
	r, _, rec := newTest()
	id := uuid.New()
	r.Touch(id, "d1", true)

	r.Leave(id, "d1")

	if got := r.State(id); got != StateOffline {
		t.Errorf("after a leaving beacon the player is %q, want %q", got, StateOffline)
	}
	if len(rec.left) != 1 || rec.left[0] != id.String()+":beacon" {
		t.Errorf("leave events = %v, want one beacon", rec.left)
	}
}

// Two devices are two sessions. Closing one must not blank the other.
func TestSecondDeviceSurvivesTheFirstLeaving(t *testing.T) {
	r, _, _ := newTest()
	id := uuid.New()
	r.Touch(id, "phone", true)
	r.Touch(id, "tablet", true)

	r.Leave(id, "phone")

	if got := r.State(id); got != StatePlaying {
		t.Errorf("with one of two sessions closed the player is %q, want %q", got, StatePlaying)
	}
	r.Leave(id, "tablet")
	if got := r.State(id); got != StateOffline {
		t.Errorf("with both sessions closed the player is %q, want %q", got, StateOffline)
	}
}

// A restart must not report an exodus that did not happen.
func TestSeedingAfterRestart(t *testing.T) {
	r, c, _ := newTest()
	recent, stale, ancient := uuid.New(), uuid.New(), uuid.New()

	r.Seed(map[uuid.UUID]time.Time{
		recent:  c.now().Add(-10 * time.Second),
		stale:   c.now().Add(-5 * time.Minute),
		ancient: c.now().Add(-2 * time.Hour),
	})

	if got := r.State(recent); got != StatePlaying {
		t.Errorf("recently-seen seeded player is %q, want %q", got, StatePlaying)
	}
	if got := r.State(stale); got != StateIdle {
		t.Errorf("stale seeded player is %q, want %q", got, StateIdle)
	}
	if got := r.State(ancient); got != StateOffline {
		t.Errorf("player last seen two hours ago was seeded as %q, want %q", got, StateOffline)
	}
	if !r.Counts().Reconciling {
		t.Error("a freshly started registry does not report itself as reconciling")
	}

	// And it stops hedging once it is old enough to know.
	c.add(ReconcileWindow + time.Second)
	if r.Counts().Reconciling {
		t.Error("registry still reconciling long after start-up")
	}
}

// A seeded guess must give way to an observation.
func TestObservationOverridesASeededGuess(t *testing.T) {
	r, c, _ := newTest()
	id := uuid.New()
	r.Seed(map[uuid.UUID]time.Time{id: c.now().Add(-5 * time.Minute)})

	if got := r.State(id); got != StateIdle {
		t.Fatalf("seeded player is %q, want %q", got, StateIdle)
	}
	r.Touch(id, "d1", true)
	if got := r.State(id); got != StatePlaying {
		t.Errorf("after acting the player is %q, want %q", got, StatePlaying)
	}
}

func TestDirtySetDrainsOnce(t *testing.T) {
	r, _, _ := newTest()
	a, b := uuid.New(), uuid.New()
	r.Touch(a, "d", false)
	r.Touch(b, "s", false)
	r.Touch(a, "d", false)

	first := r.DrainDirty()
	if len(first) != 2 {
		t.Errorf("drained %d ids, want 2 (touching one player twice is still one write)", len(first))
	}
	if second := r.DrainDirty(); second != nil {
		t.Errorf("a second drain returned %v, want nothing", second)
	}
}

// The middleware calls Touch from every request goroutine at once.
func TestConcurrentTouchIsSafe(t *testing.T) {
	r, _, _ := newTest()
	ids := make([]uuid.UUID, 50)
	for i := range ids {
		ids[i] = uuid.New()
	}

	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r.Touch(ids[i%len(ids)], "s", i%2 == 0)
			r.Snapshot()
			r.Counts()
		}(i)
	}
	wg.Wait()

	if c := r.Counts(); c.Playing != len(ids) {
		t.Errorf("playing = %d, want %d", c.Playing, len(ids))
	}
}
