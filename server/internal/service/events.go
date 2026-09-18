package service

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// ClientEvent is something the phone saw that the server could not: a screen
// opened, the app brought to the front, how long it stayed there.
type ClientEvent struct {
	Name  string         `json:"name"`
	Props map[string]any `json:"props,omitempty"`
	// At is the phone's clock, in unix seconds, when it happened.
	At int64 `json:"at,omitempty"`
}

// EventsResult says what became of a call's events.
type EventsResult struct {
	Recorded int `json:"recorded"`
	Dropped  int `json:"dropped"`
}

type propKind int

const (
	propString propKind = iota // an id: lower case, digits, _ . : -
	propInt                    // a whole number, 0 to a billion
	propBool
)

// clientEvents is every event the client may report and the properties each
// may carry. It is closed: a name or a property that is not here is dropped, so
// the table holds what someone decided to measure and never free text -- a
// string property is an id, not a sentence, and cannot carry a name or a
// message. A new event is a line here and a call to Api.track in the client;
// scripts/lint-client.py fails a client that tracks a name this does not list.
var clientEvents = map[string]map[string]propKind{
	// The game came to the front: cold is a launch, not a return from the
	// background.
	"app_open": {"cold": propBool},
	// The game left the front after this many seconds there.
	"app_close": {"seconds": propInt},
	// A tab or a page was opened. name is the tab's id or "page:<title>".
	"screen": {"name": propString},
}

const (
	// maxEventsPerCall is one flush's worth: the client sends every minute and
	// when the game leaves the front.
	maxEventsPerCall = 25
	// eventsPerHour is one player's allowance. A player switching screens as
	// fast as they can reads a few hundred; past this, a client is misbehaving
	// and its events are not worth keeping.
	eventsPerHour = 600
	maxStringProp = 48
	maxIntProp    = 1_000_000_000
	// A phone's clock is believed within this window of the server's; outside
	// it the event is kept and its client_at left empty.
	clientClockPast   = 7 * 24 * time.Hour
	clientClockFuture = time.Hour
)

// EventNames is the list, sorted, for the panel and the client lint.
func EventNames() []string {
	out := make([]string, 0, len(clientEvents))
	for n := range clientEvents {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// RecordEvents keeps a call's events that are on the list and drops the rest.
//
// Never an error for a bad event: an old build reporting a name since retired,
// or a new one ahead of this server, loses that event and nothing else. The
// call fails only when the database does.
func (d Deps) RecordEvents(ctx context.Context, playerID uuid.UUID, events []ClientEvent) (EventsResult, error) {
	var res EventsResult
	if len(events) > maxEventsPerCall {
		res.Dropped = len(events) - maxEventsPerCall
		events = events[:maxEventsPerCall]
	}
	now := d.Now()
	names := make([]string, 0, len(events))
	props := make([]string, 0, len(events))
	ats := make([]int64, 0, len(events))
	for _, e := range events {
		clean, ok := checkEvent(e)
		if !ok {
			res.Dropped++
			continue
		}
		raw, err := json.Marshal(clean)
		if err != nil {
			res.Dropped++
			continue
		}
		names = append(names, e.Name)
		props = append(props, string(raw))
		ats = append(ats, believableAt(e.At, now))
	}
	if len(names) == 0 {
		return res, nil
	}
	n, err := sqlcdb.New(d.Pool).RecordEvents(ctx, sqlcdb.RecordEventsParams{
		PlayerID: playerID, Names: names, Props: props, Ats: ats,
		Now: now, HourlyCap: eventsPerHour,
	})
	if err != nil {
		return res, fmt.Errorf("record events: %w", err)
	}
	res.Recorded = int(n)
	res.Dropped += len(names) - int(n)
	return res, nil
}

// checkEvent returns the event's properties as they will be stored, or false
// when the event is not one the server keeps.
func checkEvent(e ClientEvent) (map[string]any, bool) {
	allowed, ok := clientEvents[e.Name]
	if !ok {
		return nil, false
	}
	out := make(map[string]any, len(e.Props))
	for k, v := range e.Props {
		kind, ok := allowed[k]
		if !ok {
			return nil, false
		}
		switch kind {
		case propString:
			s, ok := v.(string)
			if !ok || !isEventID(s) {
				return nil, false
			}
			out[k] = s
		case propInt:
			f, ok := v.(float64)
			if !ok || f != math.Trunc(f) || f < 0 || f > maxIntProp {
				return nil, false
			}
			out[k] = int64(f)
		case propBool:
			b, ok := v.(bool)
			if !ok {
				return nil, false
			}
			out[k] = b
		}
	}
	return out, true
}

// isEventID holds a string property to an id's alphabet and length.
func isEventID(s string) bool {
	if s == "" || len(s) > maxStringProp {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_', r == '.', r == ':', r == '-':
		default:
			return false
		}
	}
	return true
}

// believableAt is the phone's timestamp if it is near enough the server's to
// mean something, else 0 (stored as no client time).
func believableAt(at int64, now time.Time) int64 {
	if at <= 0 {
		return 0
	}
	t := time.Unix(at, 0)
	if t.Before(now.Add(-clientClockPast)) || t.After(now.Add(clientClockFuture)) {
		return 0
	}
	return at
}
