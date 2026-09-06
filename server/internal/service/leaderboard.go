package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// Boards a player can ask for.
//
// Three axes on purpose, because one board makes one build correct. Might
// rewards investing in the army, level rewards playing, wealth rewards not
// being robbed — and the three top tens are rarely the same people.
var boardIDs = []string{"might", "level", "wealth"}

// boardSize caps both the snapshot and what a request may read.
const boardSize = 100

// LeaderRow is one place on a board.
type LeaderRow struct {
	Rank   int64  `json:"rank"`
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Level  int64  `json:"level"`
	Value  int64  `json:"value"`
}

// LeaderboardView is one board, plus where the asker stands on it.
type LeaderboardView struct {
	Board string      `json:"board"`
	Rows  []LeaderRow `json:"rows"`
	// Zero when they are not on the board at all, which for most players is the
	// honest answer and is better than an invented number.
	MyRank  int64 `json:"my_rank"`
	MyValue int64 `json:"my_value"`
}

// GetLeaderboard reads one snapshot.
func (d Deps) GetLeaderboard(ctx context.Context, playerID uuid.UUID, board string) (*LeaderboardView, error) {
	valid := false
	for _, b := range boardIDs {
		if b == board {
			valid = true
			break
		}
	}
	if !valid {
		return nil, ErrNotFound
	}

	q := sqlcdb.New(d.Pool)
	rows, err := q.ReadBoard(ctx, sqlcdb.ReadBoardParams{Board: board, Lim: boardSize})
	if err != nil {
		return nil, fmt.Errorf("leaderboard: %w", err)
	}

	out := &LeaderboardView{Board: board, Rows: make([]LeaderRow, 0, len(rows))}
	for _, r := range rows {
		out.Rows = append(out.Rows, LeaderRow{
			Rank: int64(r.Rank), Name: r.DisplayName, Avatar: r.Avatar,
			Level: int64(r.Level), Value: r.Value,
		})
	}

	// One indexed lookup rather than a scan of the board they may not be on.
	if mine, err := q.MyRank(ctx, sqlcdb.MyRankParams{Board: board, PlayerID: playerID}); err == nil {
		out.MyRank, out.MyValue = int64(mine.Rank), mine.Value
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("my rank: %w", err)
	}
	return out, nil
}

// RefreshLeaderboards rebuilds every board.
//
// All three in ONE transaction: a reader that caught the gap between clearing a
// board and filling it would see an empty leaderboard, which looks like the
// feature broke rather than like a refresh in progress.
func (d Deps) RefreshLeaderboards(ctx context.Context) error {
	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		for _, b := range boardIDs {
			if err := q.ClearBoard(ctx, b); err != nil {
				return fmt.Errorf("clear %s: %w", b, err)
			}
		}
		if err := q.FillBoardMight(ctx, boardSize); err != nil {
			return fmt.Errorf("fill might: %w", err)
		}
		if err := q.FillBoardLevel(ctx, boardSize); err != nil {
			return fmt.Errorf("fill level: %w", err)
		}
		if err := q.FillBoardWealth(ctx, boardSize); err != nil {
			return fmt.Errorf("fill wealth: %w", err)
		}
		return nil
	})
}
