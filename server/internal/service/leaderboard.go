package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
)

// Boards a player can ask for.
//
// Three axes on purpose, because one board makes one build correct. Might
// rewards investing in the army, level rewards playing, wealth rewards not
// being robbed — and the three top tens are rarely the same people.
var boardIDs = []string{"might", "level", "wealth"}

// boardSize caps both the snapshot and what a request may read.
const boardSize = 100

// LeaderRow is one place on a board. Rank is the place shown: lords level on
// a board that counts a deed share it.
type LeaderRow struct {
	Rank   int64  `json:"rank"`
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Level  int64  `json:"level"`
	Value  int64  `json:"value"`
	Look
}

// LeaderboardView is one board, plus where the asker stands on it.
type LeaderboardView struct {
	Board string      `json:"board"`
	Rows  []LeaderRow `json:"rows"`
	// Zero when they are not on the board at all, which for most players is the
	// honest answer and is better than an invented number.
	MyRank  int64 `json:"my_rank"`
	MyValue int64 `json:"my_value"`
	// The board's name and period (all | week | season); for one that closes,
	// seconds until it does and what its places are paid.
	Name    string            `json:"name"`
	Period  string            `json:"period"`
	EndsIn  int64             `json:"ends_in"`
	Rewards []PlaceRewardView `json:"rewards"`
	// Every board there is, for the page's chips.
	Boards []BoardChip `json:"boards"`
}

// BoardChip is one board as a chip names it.
type BoardChip struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Period string `json:"period"`
}

// standingBoardNames are the boards kept for all time.
var standingBoardNames = map[string]string{"might": "Might", "level": "Level", "wealth": "Wealth"}

// boardChips lists every board: the standing three, then the week's and the
// season's.
func (d Deps) boardChips() []BoardChip {
	out := make([]BoardChip, 0, len(boardIDs)+5)
	for _, id := range boardIDs {
		out = append(out, BoardChip{ID: id, Name: standingBoardNames[id], Period: PeriodAll})
	}
	for _, b := range d.timedBoards() {
		out = append(out, BoardChip{ID: b.Def.ID, Name: b.Def.Name, Period: b.Period})
	}
	return out
}

// GetLeaderboard reads one snapshot.
func (d Deps) GetLeaderboard(ctx context.Context, playerID uuid.UUID, board string) (*LeaderboardView, error) {
	var chip *BoardChip
	chips := d.boardChips()
	for i := range chips {
		if chips[i].ID == board {
			chip = &chips[i]
			break
		}
	}
	if chip == nil {
		return nil, ErrNotFound
	}

	q := sqlcdb.New(d.Pool)
	rows, err := q.ReadBoard(ctx, sqlcdb.ReadBoardParams{Board: board, Lim: boardSize})
	if err != nil {
		return nil, fmt.Errorf("leaderboard: %w", err)
	}

	out := &LeaderboardView{Board: board, Rows: make([]LeaderRow, 0, len(rows)),
		Name: chip.Name, Period: chip.Period, Rewards: []PlaceRewardView{}, Boards: chips}
	if tb := d.timedBoard(board); tb != nil {
		out.EndsIn = d.boardEndsIn(tb.Period, d.Now())
		from := 1
		for _, r := range tb.Def.Rewards {
			out.Rewards = append(out.Rewards, PlaceRewardView{From: from, To: r.Top,
				Lines: rewards.Lines(d.Config, r.Grant, rewards.Resolved{})})
			from = r.Top + 1
		}
	}
	for _, r := range rows {
		place := int64(r.Place)
		if place == 0 {
			place = int64(r.Rank)
		}
		out.Rows = append(out.Rows, LeaderRow{
			Rank: place, Name: r.DisplayName, Avatar: r.Avatar,
			Level: int64(r.Level), Value: r.Value,
			Look: lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints),
		})
	}

	// One indexed lookup rather than a scan of the board they may not be on.
	if mine, err := q.MyRank(ctx, sqlcdb.MyRankParams{Board: board, PlayerID: playerID}); err == nil {
		out.MyRank, out.MyValue = int64(mine.Place), mine.Value
		if out.MyRank == 0 {
			out.MyRank = int64(mine.Rank)
		}
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
		// The week's and the season's, in the same transaction.
		return d.fillTimedBoards(ctx, q, d.Now())
	})
}
