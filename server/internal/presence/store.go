package presence

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Store is the registry's only contact with the database: one batched write of
// last_seen_at, and one read at start-up to seed the board.
type Store struct{ pool *pgxpool.Pool }

// NewStore wires a registry flusher to the pool.
func NewStore(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

// TouchSeen writes last_seen_at for everyone the registry has heard from since
// the last flush, in a single statement.
func (s *Store) TouchSeen(ctx context.Context, ids []uuid.UUID) error {
	if len(ids) == 0 {
		return nil
	}
	return sqlcdb.New(s.pool).TouchPlayersSeen(ctx, ids)
}

// Recent reads back who was around, so a restart does not look like an exodus.
func (s *Store) Recent(ctx context.Context, since time.Time) (map[uuid.UUID]time.Time, error) {
	rows, err := sqlcdb.New(s.pool).RecentlySeenPlayers(ctx, since)
	if err != nil {
		return nil, err
	}
	out := make(map[uuid.UUID]time.Time, len(rows))
	for _, r := range rows {
		out[r.ID] = r.LastSeenAt
	}
	return out, nil
}
