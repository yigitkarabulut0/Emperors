package admin

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/presence"
)

// Publisher is the slice of the stream hub this needs.
type Publisher interface {
	Publish(kind string, payload any)
}

// LiveFeed turns presence transitions into stream frames.
//
// It exists to keep a database query out of the player's request path. The
// presence registry is touched by the game middleware on every authenticated
// request, and the panel needs a name and a level to render a new arrival --
// but looking that up inline would put a Frankfurt round trip in front of the
// tap that caused it. So the sink does nothing but hand an id to a channel, and
// this goroutine does the enriching.
//
// It also coalesces: fifty players arriving in the same second become one frame
// with fifty rows, not fifty frames.
type LiveFeed struct {
	svc *Service
	hub Publisher

	joins  chan uuid.UUID
	leaves chan leaveEvent
	counts chan presence.Counts
}

type leaveEvent struct {
	ID     uuid.UUID
	Reason string
}

// coalesce is how long arrivals are gathered before a frame goes out. Short
// enough to feel instant, long enough that a login storm is one frame.
const coalesce = 200 * time.Millisecond

// NewLiveFeed wires the registry's sink to the hub.
func NewLiveFeed(svc *Service, hub Publisher) *LiveFeed {
	return &LiveFeed{
		svc: svc, hub: hub,
		// Buffered and non-blocking on send: presence is a nice-to-have for the
		// panel and must never be able to slow the game down. A full channel
		// drops the notification; the next sweep's counts frame corrects it.
		joins:  make(chan uuid.UUID, 256),
		leaves: make(chan leaveEvent, 256),
		counts: make(chan presence.Counts, 8),
	}
}

// PresenceJoined implements presence.Sink.
func (f *LiveFeed) PresenceJoined(v presence.View) {
	select {
	case f.joins <- v.PlayerID:
	default:
	}
}

// PresenceLeft implements presence.Sink.
func (f *LiveFeed) PresenceLeft(id uuid.UUID, reason string) {
	select {
	case f.leaves <- leaveEvent{ID: id, Reason: reason}:
	default:
	}
}

// PresenceCounts implements presence.Sink.
func (f *LiveFeed) PresenceCounts(c presence.Counts) {
	select {
	case f.counts <- c:
	default:
	}
}

// Run pumps until the context is cancelled.
func (f *LiveFeed) Run(ctx context.Context) error {
	pending := make(map[uuid.UUID]struct{})
	var flushAt <-chan time.Time
	// Counts change on every transition; the panel only needs the latest.
	var latest *presence.Counts
	countTick := time.NewTicker(time.Second)
	defer countTick.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil

		case id := <-f.joins:
			pending[id] = struct{}{}
			if flushAt == nil {
				flushAt = time.After(coalesce)
			}

		case <-flushAt:
			flushAt = nil
			f.publishJoins(ctx, pending)
			pending = make(map[uuid.UUID]struct{})

		case ev := <-f.leaves:
			// No lookup needed: the panel already knows everyone it is showing.
			f.hub.Publish("presence.left", map[string]any{
				"id": ev.ID.String(), "reason": ev.Reason,
			})

		case c := <-f.counts:
			latest = &c

		case <-countTick.C:
			if latest != nil {
				f.hub.Publish("presence.counts", latest)
				latest = nil
			}
		}
	}
}

func (f *LiveFeed) publishJoins(ctx context.Context, ids map[uuid.UUID]struct{}) {
	if len(ids) == 0 {
		return
	}
	list := make([]uuid.UUID, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := f.svc.LiveRowsFor(ctx, list)
	if err != nil {
		// The panel is not left wrong, only less informed: it still gets the
		// counts, and its next fetch of the board fills in the names.
		return
	}
	if len(rows) == 0 {
		return
	}
	f.hub.Publish("presence.joined", map[string]any{"players": rows})
}
