package service

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/liveops"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// The boards that close (liveops.ranks): the week's, over the UTC week every
// lord shares, and the season's. They are rebuilt with the standing boards
// (RefreshLeaderboards) and paid by letter when their period ends
// (closeBoards). The season's renown -- its Charter points -- also names the
// season's nobility, worn through the season after, and its close sends each
// lord what their Charter still held.

// Periods a board is kept over.
const (
	PeriodAll    = "all"
	PeriodWeek   = "week"
	PeriodSeason = "season"
)

// The period_closes rows a season's close writes besides its boards'.
const (
	closeNobility    = "nobility"
	closeCharterLeft = "charter_left"
)

// timedBoard is a board that closes, and the period it is kept over.
type timedBoard struct {
	Def    gameconfig.BoardDef
	Period string
}

// timedBoards is every board that closes, the week's first.
func (d Deps) timedBoards() []timedBoard {
	var out []timedBoard
	for _, b := range d.Config.LiveOps.Ranks.Weekly {
		out = append(out, timedBoard{Def: b, Period: PeriodWeek})
	}
	for _, b := range d.Config.LiveOps.Ranks.Season {
		out = append(out, timedBoard{Def: b, Period: PeriodSeason})
	}
	return out
}

// timedBoard returns the closing board with this id, or nil.
func (d Deps) timedBoard(id string) *timedBoard {
	for _, b := range d.timedBoards() {
		if b.Def.ID == id {
			b := b
			return &b
		}
	}
	return nil
}

// boardsEpoch is the first UTC week the boards were kept: the first season's.
// A week before it is never closed -- nobody played it for a prize.
func (d Deps) boardsEpoch() int64 {
	epoch, err := time.Parse("2006-01-02", d.Config.LiveOps.Season.Epoch)
	if err != nil {
		return 0
	}
	return deeds.UWeek(epoch)
}

// fillTimedBoards rebuilds the week's and the season's boards, inside the
// standing boards' transaction.
func (d Deps) fillTimedBoards(ctx context.Context, q *sqlcdb.Queries, now time.Time) error {
	uw := deeds.UWeek(now)
	season := d.seasonNow(now)
	for _, b := range d.timedBoards() {
		if err := q.ClearBoard(ctx, b.Def.ID); err != nil {
			return fmt.Errorf("clear %s: %w", b.Def.ID, err)
		}
		var err error
		switch {
		case b.Period == PeriodWeek:
			err = q.FillDeedBoard(ctx, sqlcdb.FillDeedBoardParams{
				Board: b.Def.ID, Scope: deeds.ScopeUWeek, Period: uw, Deed: b.Def.Deed, Lim: boardSize,
			})
		case season.Number < 1:
			continue
		case b.Def.Deed == gameconfig.BoardRenown:
			err = q.FillRenownBoard(ctx, sqlcdb.FillRenownBoardParams{
				Board: b.Def.ID, Season: int32(season.Number), Lim: boardSize,
			})
		case b.Def.Deed == gameconfig.BoardMightGain:
			err = q.FillMightGainBoard(ctx, sqlcdb.FillMightGainBoardParams{
				Board: b.Def.ID, Season: int32(season.Number), Lim: boardSize,
			})
		case b.Def.Deed == gameconfig.BoardArenaRating:
			err = q.FillArenaBoard(ctx, sqlcdb.FillArenaBoardParams{
				Board: b.Def.ID, Season: int32(season.Number), Lim: boardSize,
			})
		default:
			err = q.FillDeedBoard(ctx, sqlcdb.FillDeedBoardParams{
				Board: b.Def.ID, Scope: deeds.ScopeSeason, Period: int64(season.Number), Deed: b.Def.Deed, Lim: boardSize,
			})
		}
		if err != nil {
			return fmt.Errorf("fill %s: %w", b.Def.ID, err)
		}
	}
	return nil
}

// boardEndsIn is how long a board's period has left.
func (d Deps) boardEndsIn(period string, now time.Time) int64 {
	switch period {
	case PeriodWeek:
		next := time.Unix((deeds.UWeek(now)+7)*86400, 0).UTC()
		return secondsUntil(next, now)
	case PeriodSeason:
		return secondsUntil(d.seasonNow(now).End, now)
	}
	return 0
}

// closeBoards pays every board whose period has ended, then crowns the
// season's nobility and sends what its Charters held. Each step writes its
// period_closes row when done, and every letter carries an idempotency key,
// so a close that died half way runs again safely.
func closeBoards(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	lastWeek := deeds.UWeek(now) - 7
	lastSeason := d.seasonNow(now).Number - 1
	for _, b := range d.timedBoards() {
		var period int64
		switch b.Period {
		case PeriodWeek:
			if lastWeek < d.boardsEpoch() {
				continue
			}
			period = lastWeek
		case PeriodSeason:
			if lastSeason < 1 {
				continue
			}
			period = int64(lastSeason)
		}
		done, err := q.PeriodClosed(ctx, sqlcdb.PeriodClosedParams{What: b.Def.ID, Period: period})
		if err != nil {
			return fmt.Errorf("closed %s: %w", b.Def.ID, err)
		}
		if done {
			continue
		}
		n, err := d.payBoard(ctx, q, b, period)
		if err != nil {
			return fmt.Errorf("pay %s %d: %w", b.Def.ID, period, err)
		}
		if err := q.ClosePeriod(ctx, sqlcdb.ClosePeriodParams{What: b.Def.ID, Period: period, Lords: int32(n)}); err != nil {
			return err
		}
	}
	if lastSeason < 1 {
		return nil
	}
	for _, step := range []struct {
		what string
		run  func(context.Context, int) (int, error)
	}{{closeNobility, d.crownNobility}, {closeCharterLeft, d.sendCharterLeftovers}} {
		done, err := q.PeriodClosed(ctx, sqlcdb.PeriodClosedParams{What: step.what, Period: int64(lastSeason)})
		if err != nil {
			return err
		}
		if done {
			continue
		}
		n, err := step.run(ctx, lastSeason)
		if err != nil {
			return fmt.Errorf("%s %d: %w", step.what, lastSeason, err)
		}
		if err := q.ClosePeriod(ctx, sqlcdb.ClosePeriodParams{What: step.what, Period: int64(lastSeason), Lords: int32(n)}); err != nil {
			return err
		}
	}
	return nil
}

// standing is one lord's place on a closed board.
type standing struct {
	PlayerID uuid.UUID
	Value    int64
	Place    int
}

// closedStandings is a closed period's places, as far as the board pays.
func (d Deps) closedStandings(ctx context.Context, q *sqlcdb.Queries, b timedBoard, period int64) ([]standing, error) {
	last := 0
	if n := len(b.Def.Rewards); n > 0 {
		last = b.Def.Rewards[n-1].Top
	}
	var out []standing
	if b.Def.Deed == gameconfig.BoardMightGain {
		rows, err := q.MightGainStandings(ctx, sqlcdb.MightGainStandingsParams{Season: int32(period), Lim: int32(last)})
		if err != nil {
			return nil, err
		}
		for _, r := range rows {
			out = append(out, standing{PlayerID: r.PlayerID, Value: r.Value, Place: int(r.Place)})
		}
		return out, nil
	}
	if b.Def.Deed == gameconfig.BoardArenaRating {
		rows, err := q.ArenaStandings(ctx, sqlcdb.ArenaStandingsParams{
			Season: int32(period), Lim: int32(last),
		})
		if err != nil {
			return nil, err
		}
		for _, r := range rows {
			out = append(out, standing{PlayerID: r.PlayerID, Value: int64(r.Value), Place: int(r.Place)})
		}
		return out, nil
	}
	if b.Def.Deed == gameconfig.BoardRenown {
		rows, err := q.SeasonStandings(ctx, int32(period))
		if err != nil {
			return nil, err
		}
		for i, r := range rows {
			if i >= last {
				break
			}
			out = append(out, standing{PlayerID: r.PlayerID, Value: r.PointsMilli / 1000, Place: i + 1})
		}
		return out, nil
	}
	scope := deeds.ScopeUWeek
	if b.Period == PeriodSeason {
		scope = deeds.ScopeSeason
	}
	rows, err := q.DeedStandings(ctx, sqlcdb.DeedStandingsParams{Scope: scope, Period: period, Deed: b.Def.Deed, Lim: int32(last)})
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out = append(out, standing{PlayerID: r.PlayerID, Value: r.Value, Place: int(r.Place)})
	}
	return out, nil
}

// payBoard sends each place its letter.
func (d Deps) payBoard(ctx context.Context, q *sqlcdb.Queries, b timedBoard, period int64) (int, error) {
	rows, err := d.closedStandings(ctx, q, b, period)
	if err != nil {
		return 0, err
	}
	what := "The week of " + time.Unix(period*86400, 0).UTC().Format("2 January")
	if b.Period == PeriodSeason {
		what = fmt.Sprintf("Season %d", period)
	}
	for _, r := range rows {
		g := liveops.PlaceReward(b.Def.Rewards, r.Place)
		if g == nil {
			continue
		}
		if _, err := d.SendMail(ctx, q, r.PlayerID, MailDraft{
			Kind: MailBoard, Title: fmt.Sprintf("%s: %s place", b.Def.Name, ordinal(r.Place)),
			Body: fmt.Sprintf("%s is over. On its board you finished %s, with %s. The Crown sends your prize.",
				what, ordinal(r.Place), boardValue(b.Def.Deed, r.Value)),
			Attachments: *g, IdemKey: fmt.Sprintf("board:%s:%d", b.Def.ID, period),
		}); err != nil {
			return 0, err
		}
	}
	return len(rows), nil
}

// boardValue writes out a board's count: "35 raids won", "1,204 renown".
func boardValue(deed string, n int64) string {
	switch deed {
	case gameconfig.BoardRenown:
		return rewards.Group(n) + " renown"
	case gameconfig.BoardMightGain:
		return rewards.Group(n) + " Might gained"
	case gameconfig.BoardArenaRating:
		return "a rating of " + rewards.Group(n)
	}
	w, ok := deedWords[deed]
	if !ok {
		return rewards.Group(n)
	}
	if n == 1 {
		return "1 " + w[0]
	}
	return rewards.Group(n) + " " + w[1]
}

// crownNobility names a closed season's nobles from its renown, and gives each
// their rank's frame and title through the season after it.
func (d Deps) crownNobility(ctx context.Context, season int) (int, error) {
	q := sqlcdb.New(d.Pool)
	rows, err := q.SeasonStandings(ctx, int32(season))
	if err != nil {
		return 0, err
	}
	sc := d.Config.LiveOps.Season
	board := make([]liveops.Standing, 0, len(rows))
	for i, r := range rows {
		board = append(board, liveops.Standing{
			Key: r.PlayerID.String(), Place: i + 1,
			Tier: liveops.Tier(r.PointsMilli/1000, sc.PointsPerTier, sc.Tiers),
		})
	}
	nobles := liveops.Nobility(d.Config.LiveOps.Ranks.Nobility, board)
	until := liveops.SeasonNumbered(sc, season+1).End
	ref := fmt.Sprintf("nobility:%d", season)
	keys := make([]string, 0, len(nobles))
	for k := range nobles {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		rank := nobles[k]
		id, _ := uuid.Parse(k)
		frame, title := "frame_noble_"+rank, "title_noble_"+rank
		name := rank
		if c := d.Config.Cosmetic(title); c != nil {
			name = c.Name
		}
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			sent, err := d.SendMail(ctx, tq, id, MailDraft{
				Kind: "season", Title: fmt.Sprintf("The Crown names you %s", name),
				Body: fmt.Sprintf("For your deeds in Season %d the Crown names you %s of the realm. The %s's frame and title are yours to wear through Season %d.",
					season, name, name, season+1),
				IdemKey: ref,
			})
			if err != nil || !sent {
				return err
			}
			for _, c := range []string{frame, title} {
				if d.Config.Cosmetic(c) == nil {
					continue
				}
				if err := tq.HoldCosmeticUntil(ctx, sqlcdb.HoldCosmeticUntilParams{
					PlayerID: id, CosmeticID: c, Source: "nobility", SourceRef: &ref, Until: &until,
				}); err != nil {
					return fmt.Errorf("hold %s: %w", c, err)
				}
			}
			return nil
		})
		if err != nil {
			return 0, err
		}
	}
	return len(nobles), nil
}

// sendCharterLeftovers pays each lord of a closed season what their Charter
// had reached and they had not claimed. The royal lane holds no gear, so it
// is paid at once (as the purchase that opened it, when one did); the free
// lane's is sent by letter, to be claimed when the armory has room.
func (d Deps) sendCharterLeftovers(ctx context.Context, season int) (int, error) {
	rows, err := sqlcdb.New(d.Pool).SeasonRows(ctx, int32(season))
	if err != nil {
		return 0, err
	}
	n := 0
	for _, r := range rows {
		free, royal := d.charterOpen(r)
		if len(free)+len(royal) == 0 {
			continue
		}
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			q := sqlcdb.New(tx)
			p, err := q.LockPlayer(ctx, r.PlayerID)
			if err != nil {
				return fmt.Errorf("lock player: %w", err)
			}
			row, err := q.GetPlayerSeason(ctx, sqlcdb.GetPlayerSeasonParams{PlayerID: p.ID, Season: int32(season)})
			if err != nil {
				return fmt.Errorf("season row: %w", err)
			}
			free, royal := d.charterOpen(row)
			if len(free)+len(royal) == 0 {
				return nil
			}
			if _, err := q.ClaimSeasonTiers(ctx, sqlcdb.ClaimSeasonTiersParams{
				PlayerID: p.ID, Season: row.Season,
				Free: int64(liveops.Mask(free)), Royal: int64(liveops.Mask(royal)),
			}); err != nil {
				return fmt.Errorf("mark leftovers: %w", err)
			}
			sc := d.Config.LiveOps.Season
			var paid []string
			for _, i := range royal {
				g, err := d.grantBundle(ctx, q, &p, sc.Royal[i], royalSource(row, i+1))
				if err != nil {
					return err
				}
				for _, l := range g.Lines {
					paid = append(paid, l.Text)
				}
			}
			var left gameconfig.RewardBundle
			for _, i := range free {
				left = rewards.Merge(left, sc.Free[i])
			}
			body := fmt.Sprintf("Season %d has ended with rewards on your Charter still unclaimed.", season)
			if len(paid) > 0 {
				// A letter's body has room for a dozen lines; the rest are counted.
				shown := paid
				if len(shown) > 12 {
					shown = append(shown[:12:12], fmt.Sprintf("and %d more", len(paid)-12))
				}
				body += " Your royal lane's are paid already: " + strings.Join(shown, ", ") + "."
			}
			if len(free) > 0 {
				body += " The free lane's are enclosed."
			}
			_, err = d.SendMail(ctx, q, p.ID, MailDraft{
				Kind: "season", Title: fmt.Sprintf("What Season %d's Charter still held", season),
				Body: body, Attachments: left, IdemKey: fmt.Sprintf("charter:%d:left", season),
			})
			return err
		})
		if err != nil {
			return 0, err
		}
		n++
	}
	return n, nil
}
