package service

import (
	"strings"
	"testing"
	"time"
)

// The listed events pass with their properties, as they will be stored.
func TestListedEventsPass(t *testing.T) {
	for _, e := range []ClientEvent{
		{Name: "app_open", Props: map[string]any{"cold": true}},
		{Name: "app_open"},
		{Name: "app_close", Props: map[string]any{"seconds": float64(754)}},
		{Name: "screen", Props: map[string]any{"name": "collect"}},
		{Name: "screen", Props: map[string]any{"name": "page:royal_mail"}},
	} {
		got, ok := checkEvent(e)
		if !ok {
			t.Fatalf("%s %v was dropped", e.Name, e.Props)
		}
		if s, ok := got["seconds"]; ok && s != int64(754) {
			t.Fatalf("seconds stored as %T %v, want a whole number", s, s)
		}
	}
}

// Anything not on the list is dropped: a name, a property, a type, a value
// that could carry more than an id.
func TestUnlistedEventsAreDropped(t *testing.T) {
	for why, e := range map[string]ClientEvent{
		"unknown name":        {Name: "purchase_start"},
		"unknown property":    {Name: "screen", Props: map[string]any{"name": "collect", "user": "bob"}},
		"string where a bool": {Name: "app_open", Props: map[string]any{"cold": "yes"}},
		"fraction":            {Name: "app_close", Props: map[string]any{"seconds": 1.5}},
		"negative":            {Name: "app_close", Props: map[string]any{"seconds": float64(-1)}},
		"too large":           {Name: "app_close", Props: map[string]any{"seconds": float64(2e9)}},
		"a sentence":          {Name: "screen", Props: map[string]any{"name": "Hello there"}},
		"upper case":          {Name: "screen", Props: map[string]any{"name": "Collect"}},
		"empty id":            {Name: "screen", Props: map[string]any{"name": ""}},
		"too long":            {Name: "screen", Props: map[string]any{"name": strings.Repeat("a", 49)}},
		"an address":          {Name: "screen", Props: map[string]any{"name": "me@example.com"}},
	} {
		if _, ok := checkEvent(e); ok {
			t.Errorf("%s: %s %v was kept", why, e.Name, e.Props)
		}
	}
}

// A phone's clock is kept when it is believable and left out when it is not.
func TestAPhonesClockIsBelievedWithinReason(t *testing.T) {
	now := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		at   time.Time
		keep bool
	}{
		{now.Add(-time.Minute), true},
		{now.Add(-6 * 24 * time.Hour), true},
		{now.Add(30 * time.Minute), true},
		{now.Add(-8 * 24 * time.Hour), false},
		{now.Add(2 * time.Hour), false},
	} {
		got := believableAt(c.at.Unix(), now)
		if (got != 0) != c.keep {
			t.Errorf("a phone clock at %s kept=%v, want %v", c.at.Sub(now), got != 0, c.keep)
		}
	}
	if believableAt(0, now) != 0 {
		t.Fatal("no timestamp became one")
	}
}
