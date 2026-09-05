package gameconfig

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"
)

// Loader fetches the currently active balance document.
type Loader interface {
	// ActiveDoc returns the live version id and its published bytes.
	ActiveDoc(ctx context.Context) (version int, raw []byte, err error)
}

// Store holds the live bundle and swaps it atomically when a new version is
// published.
//
// Readers take the pointer once per request and use it throughout, so a publish
// mid-request cannot change the rules underneath a transaction that has already
// started pricing something.
type Store struct {
	current atomic.Pointer[Bundle]
	loader  Loader
	log     *slog.Logger
}

// NewStore starts from the embedded seed, so the server can boot and serve even
// if the database has no published version yet.
func NewStore(seed *Bundle, loader Loader, log *slog.Logger) *Store {
	s := &Store{loader: loader, log: log}
	s.current.Store(seed)
	return s
}

// Get returns the live bundle. Never nil.
func (s *Store) Get() *Bundle { return s.current.Load() }

// Refresh loads the active version and swaps it in if it changed.
//
// A version that fails to parse or validate is REFUSED and the previous bundle
// stays live. A bad publish must not be able to take the game down; the panel
// validates before writing, and this is the second line of defence.
func (s *Store) Refresh(ctx context.Context) error {
	if s.loader == nil {
		return nil
	}
	version, raw, err := s.loader.ActiveDoc(ctx)
	if err != nil {
		return err
	}
	if version == 0 {
		return nil // nothing published yet; the seed stays live
	}
	if cur := s.Get(); cur != nil && cur.Version == version {
		return nil
	}

	doc, err := ParseDoc(raw)
	if err != nil {
		return fmt.Errorf("version %d is unparseable, keeping the current one: %w", version, err)
	}
	b, err := FromDoc(version, doc)
	if err != nil {
		return fmt.Errorf("version %d is invalid, keeping the current one: %w", version, err)
	}

	s.current.Store(b)
	if s.log != nil {
		s.log.Info("balance version activated", "version", version, "jobs", len(b.Jobs.Jobs))
	}
	return nil
}

// Watch polls for new versions until the context ends.
//
// Polling rather than LISTEN/NOTIFY: a poll survives a dropped connection with
// no reconnect logic, and a config change that takes up to a minute to reach
// players is completely acceptable for balance data.
func (s *Store) Watch(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := s.Refresh(ctx); err != nil && s.log != nil {
				s.log.Warn("balance refresh failed", "err", err)
			}
		}
	}
}
