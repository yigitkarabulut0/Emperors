package admin

import (
	"context"
	"sort"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/presence"
)

// LiveRow is one player on the live board: their presence, plus enough identity
// to render them without the panel asking again.
type LiveRow struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Level    int    `json:"level"`
	Gold     string `json:"gold"`
	Diamonds int64  `json:"diamonds"`
	State    string `json:"state"`

	// Presence is "playing" or "idle".
	Presence string `json:"presence"`
	// Since is when this stretch of presence began, so the panel can show how
	// long they have been in.
	Since      time.Time `json:"since"`
	SecondsIn  int       `json:"seconds_in"`
	SecondsAgo int       `json:"seconds_ago"`
	// Inferred says presence was read off ordinary game traffic rather than an
	// explicit heartbeat, because this client's build predates it. The panel
	// must show the difference rather than present a guess as a fact.
	Inferred bool  `json:"inferred"`
	Devices  int   `json:"devices"`
	Requests int64 `json:"requests"`
}

// LiveBoard is the whole answer to "who is in the game right now".
type LiveBoard struct {
	Playing []LiveRow `json:"playing"`
	Idle    []LiveRow `json:"idle"`

	CountPlaying int   `json:"count_playing"`
	CountIdle    int   `json:"count_idle"`
	Registered   int64 `json:"registered"`
	// Offline is the rest of the roster: registered minus everyone accounted for.
	Offline int64 `json:"offline"`

	// Reconciling is true for the first minute and a half after a restart, while
	// the registry has been seeded from last_seen_at but has not yet heard from
	// people itself. Saying so is better than reporting an exodus that did not
	// happen.
	Reconciling bool      `json:"reconciling"`
	At          time.Time `json:"at"`
}

// Live returns the board. Reads the in-memory registry, then one query for the
// identities behind it — never one query per row.
func (s *Service) Live(ctx context.Context) (*LiveBoard, error) {
	if s.Presence == nil {
		return &LiveBoard{Playing: []LiveRow{}, Idle: []LiveRow{}, At: s.now()}, nil
	}

	views := s.Presence.Snapshot()
	counts := s.Presence.Counts()
	now := s.now()

	board := &LiveBoard{
		Playing: []LiveRow{}, Idle: []LiveRow{},
		CountPlaying: counts.Playing, CountIdle: counts.Idle,
		Reconciling: counts.Reconciling, At: now,
	}

	q := sqlcdb.New(s.Pool)
	if total, err := q.TotalRegistered(ctx); err == nil {
		board.Registered = total
	}

	if len(views) == 0 {
		board.Offline = board.Registered
		return board, nil
	}

	rows, err := s.rowsFor(ctx, views, now)
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		if row.Presence == string(presence.StateIdle) {
			board.Idle = append(board.Idle, row)
		} else {
			board.Playing = append(board.Playing, row)
		}
	}

	// Longest in the game first: the panel is a board to watch, and the person
	// who has been playing for an hour is more interesting than the one who
	// tapped once.
	sort.Slice(board.Playing, func(i, j int) bool {
		return board.Playing[i].SecondsIn > board.Playing[j].SecondsIn
	})
	sort.Slice(board.Idle, func(i, j int) bool {
		return board.Idle[i].SecondsAgo < board.Idle[j].SecondsAgo
	})

	board.CountPlaying = len(board.Playing)
	board.CountIdle = len(board.Idle)
	board.Offline = board.Registered - int64(board.CountPlaying+board.CountIdle)
	if board.Offline < 0 {
		board.Offline = 0
	}
	return board, nil
}

// LiveRowsFor builds board rows for a specific set of players, for the stream's
// arrival frames. One query for the whole batch, never one per player.
func (s *Service) LiveRowsFor(ctx context.Context, ids []uuid.UUID) ([]LiveRow, error) {
	if s.Presence == nil || len(ids) == 0 {
		return nil, nil
	}
	wanted := make(map[uuid.UUID]struct{}, len(ids))
	for _, id := range ids {
		wanted[id] = struct{}{}
	}
	views := make([]presence.View, 0, len(ids))
	for _, v := range s.Presence.Snapshot() {
		if _, ok := wanted[v.PlayerID]; ok {
			views = append(views, v)
		}
	}
	return s.rowsFor(ctx, views, s.now())
}

// rowsFor joins presence views to player identity in a single query.
func (s *Service) rowsFor(ctx context.Context, views []presence.View, now time.Time) ([]LiveRow, error) {
	if len(views) == 0 {
		return nil, nil
	}
	ids := make([]uuid.UUID, 0, len(views))
	for _, v := range views {
		ids = append(ids, v.PlayerID)
	}
	rows, err := sqlcdb.New(s.Pool).PlayersByIDs(ctx, ids)
	if err != nil {
		return nil, err
	}
	byID := make(map[uuid.UUID]sqlcdb.PlayersByIDsRow, len(rows))
	for _, r := range rows {
		byID[r.ID] = r
	}

	out := make([]LiveRow, 0, len(views))
	for _, v := range views {
		p, ok := byID[v.PlayerID]
		// A presence entry with no player row is a deleted account still holding
		// a valid token. Skip it rather than render a blank line.
		if !ok || p.IsBot {
			continue
		}
		out = append(out, LiveRow{
			ID: p.ID.String(), Username: p.Username, Name: p.DisplayName,
			Level: int(p.Level), Gold: strconv.FormatInt(p.Gold, 10), Diamonds: p.Diamonds,
			State:      p.State,
			Presence:   string(v.State),
			Since:      v.Since,
			SecondsIn:  int(now.Sub(v.Since).Seconds()),
			SecondsAgo: v.SecondsAgo,
			Inferred:   v.Inferred,
			Devices:    v.Devices,
			Requests:   v.Requests,
		})
	}
	return out, nil
}
