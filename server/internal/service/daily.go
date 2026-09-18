package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/calendar"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// The 28-day calendar (retention.calendar): a square a day, the seventh of each
// week a crown. Miss a day or two and the run is broken -- mended with diamonds
// or a Royal Pardon, or begun anew; miss more and it starts over by itself. The
// rules are game/calendar's; this is the lord's row and the pay.

var (
	// ErrAlreadyClaimed is today's square (or a task, or a chest) already taken.
	ErrAlreadyClaimed = errors.New("you have already collected today")
	// ErrCalendarBroken is a claim on a broken run without saying how to mend it.
	ErrCalendarBroken = errors.New("your run of daily rewards is broken: mend it or start anew")
	// ErrNothingToMend is paying to mend a run that is not broken.
	ErrNothingToMend = errors.New("your run is not broken")
	// ErrBadMend is a way of mending the calendar does not know.
	ErrBadMend = errors.New("that is not a way to mend a run")
)

// Square states, as the page draws them.
const (
	squareClaimed = "claimed"
	squareToday   = "today"
	squareAhead   = "ahead"
)

// CalendarSquare is one of the 28 as the page shows it.
type CalendarSquare struct {
	Day   int    `json:"day"`
	Crown bool   `json:"crown"`
	State string `json:"state"`
	// The square's picture (calendar.png's): diamonds, purse, flask, scroll,
	// cart or crown; and its main line's icon, amount and words for the plate.
	Kind   string         `json:"kind"`
	Icon   string         `json:"icon"`
	Amount int64          `json:"amount"`
	Text   string         `json:"text"`
	Lines  []rewards.Line `json:"lines"`
}

// CalendarBreak is a broken run, and what mending it takes.
type CalendarBreak struct {
	Missed          int   `json:"missed"`
	RestoreDiamonds int64 `json:"restore_diamonds"`
	CanRestore      bool  `json:"can_restore"`
	CanPardon       bool  `json:"can_pardon"`
}

// DailyView is the calendar as the lord sees it.
type DailyView struct {
	// The square today's claim takes (or took), 1-28.
	Day          int              `json:"day"`
	Claimable    bool             `json:"claimable"`
	ClaimedToday bool             `json:"claimed_today"`
	Streak       int              `json:"streak"`
	Cycle        int              `json:"cycle"`
	Broken       *CalendarBreak   `json:"broken"`
	Pardons      int64            `json:"pardons"`
	PardonsMax   int64            `json:"pardons_max"`
	Diamonds     int64            `json:"diamonds"`
	Squares      []CalendarSquare `json:"squares"`
	// What the seven-square page of the builds before the calendar reads:
	// today's diamonds and each square's. New code reads Squares.
	Reward  int64   `json:"reward"`
	Rewards []int64 `json:"rewards"`
}

// DailyClaim is what a claim paid, with the calendar and the lord after it.
type DailyClaim struct {
	Lines    []rewards.Line `json:"lines"`
	Daily    *DailyView     `json:"daily"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// localDay is the calendar date where the player actually lives.
//
// A daily reward that turns over at UTC midnight is a daily reward that turns
// over in the middle of the afternoon for a third of the world. The offset is
// captured from the device at signup (players.reset_offset_minutes).
func localDay(now time.Time, offsetMinutes int32) time.Time {
	t := now.UTC().Add(time.Duration(offsetMinutes) * time.Minute)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

// calendarState is the lord's run as game/calendar reads it.
func calendarState(p sqlcdb.AppPlayer) calendar.State {
	s := calendar.State{Pos: int(p.CalendarPos), Streak: int(p.DailyStreak), Cycle: int(p.CalendarCycle)}
	if p.DailyClaimedOn.Valid {
		s.ClaimedOn = localDay(p.DailyClaimedOn.Time.UTC(), 0)
	}
	return s
}

// calendarStatus is the run as it reads today.
func (d Deps) calendarStatus(p sqlcdb.AppPlayer, now time.Time) calendar.Status {
	return calendar.Read(calendarState(p), d.Config.Retention.Calendar.GraceDays,
		localDay(now, p.ResetOffsetMinutes))
}

// calendarSquares lays out the 28 for a lord at this level, with what each
// would pay today: the lines of the reward path itself (rewards.Resolve), so a
// purse square says the gold a claim would really give.
func calendarSquares(cfg *gameconfig.Bundle, st calendar.Status, level int, bonuses economy.Bonuses) []CalendarSquare {
	sq := cfg.Retention.Calendar.Squares
	out := make([]CalendarSquare, 0, len(sq))
	for i, s := range sq {
		day := i + 1
		state := squareAhead
		switch {
		case day == st.Square && st.ClaimedToday:
			// TODAY'S SQUARE, ALREADY TAKEN. It used to stay "today" until
			// tomorrow, so a lord claimed their gift and the tile kept its
			// waiting glow with no seal on it: the calendar never said what
			// they had taken. The square a claim has been made on is a claimed
			// square, whatever day it is.
			state = squareClaimed
		case day == st.Square:
			state = squareToday
		case day < st.Square && !st.Lapsed:
			state = squareClaimed
		}
		lines := rewards.Lines(cfg, s.Grant, rewards.Resolve(cfg, s.Grant, level, bonuses))
		v := CalendarSquare{Day: day, Crown: s.Crown, State: state, Kind: s.Kind, Lines: lines}
		if main := squareLine(lines, s.Crown); main != nil {
			v.Icon, v.Amount, v.Text = main.Icon, main.Amount, main.Text
		}
		out = append(out, v)
	}
	return out
}

// squareLine is the line a square's plate shows: its one reward, or on a crown
// the prize the crown is for (the cosmetic or the gear, not the diamonds).
func squareLine(lines []rewards.Line, crown bool) *rewards.Line {
	if len(lines) == 0 {
		return nil
	}
	if crown {
		for i := range lines {
			if lines[i].Kind == "cosmetic" || lines[i].Kind == "item" {
				return &lines[i]
			}
		}
	}
	return &lines[0]
}

// GetDaily reports the calendar.
func (d Deps) GetDaily(ctx context.Context, playerID uuid.UUID) (*DailyView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("daily: %w", err)
	}
	return d.dailyView(ctx, q, p)
}

func (d Deps) dailyView(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (*DailyView, error) {
	eff, err := d.loadEffects(ctx, q, p)
	if err != nil {
		return nil, err
	}
	held, err := tokenCounts(ctx, q, p.ID)
	if err != nil {
		return nil, err
	}
	cal := d.Config.Retention.Calendar
	st := d.calendarStatus(p, d.Now())
	v := &DailyView{
		Day: st.Square, Claimable: st.Claimable, ClaimedToday: st.ClaimedToday,
		Streak: int(p.DailyStreak), Cycle: int(p.CalendarCycle),
		Pardons: held["pardon"], PardonsMax: cal.PardonsMax, Diamonds: p.Diamonds,
		Squares: calendarSquares(d.Config, st, int(p.Level), rewards.PermanentOnly(eff.Bonuses)),
	}
	if st.Lapsed {
		v.Streak = 0
	}
	if st.Broken {
		price := cal.RestoreDiamonds[st.Missed-1]
		v.Broken = &CalendarBreak{Missed: st.Missed, RestoreDiamonds: price,
			CanRestore: p.Diamonds >= price, CanPardon: held["pardon"] > 0}
	}
	v.Rewards = make([]int64, len(cal.Squares))
	for i, s := range cal.Squares {
		v.Rewards[i] = s.Grant.Diamonds
	}
	if st.Square >= 1 && st.Square <= len(cal.Squares) {
		v.Reward = cal.Squares[st.Square-1].Grant.Diamonds
	}
	return v, nil
}

// ClaimDaily takes today's square, mending a broken run the way mend says.
//
// Idempotent by construction: the claim's UPDATE only matches a lord who has
// not claimed on this local date, so two taps or two devices cannot both be
// paid. Asynchronous like a letter -- action_seq is not touched; the answer's
// snapshot is adopted as one.
func (d Deps) ClaimDaily(ctx context.Context, playerID uuid.UUID, mend string) (*DailyClaim, error) {
	m := calendar.Mend(mend)
	switch m {
	case calendar.MendNone, calendar.MendDiamonds, calendar.MendPardon, calendar.MendAnew:
	default:
		return nil, ErrBadMend
	}
	var lines []rewards.Line
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		cal := d.Config.Retention.Calendar
		now := d.Now()
		today := localDay(now, p.ResetOffsetMinutes)
		st := calendar.Read(calendarState(p), cal.GraceDays, today)
		after, square, begins, err := calendar.Claim(calendarState(p), cal.GraceDays, today, m)
		switch {
		case errors.Is(err, calendar.ErrClaimed):
			return ErrAlreadyClaimed
		case errors.Is(err, calendar.ErrBroken):
			return ErrCalendarBroken
		case errors.Is(err, calendar.ErrNoBreak):
			return ErrNothingToMend
		case err != nil:
			return err
		}
		if square < 1 || square > len(cal.Squares) {
			return ErrNothingToBuy
		}
		ref := fmt.Sprintf("calendar:%s:%d", today.Format("2006-01-02"), square)

		// The mend is paid first: a claim that cannot be paid for is no claim.
		switch m {
		case calendar.MendDiamonds:
			price := cal.RestoreDiamonds[st.Missed-1]
			spent, err := q.SpendDiamonds(ctx, sqlcdb.SpendDiamondsParams{ID: p.ID, Amount: price})
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNotEnoughDiamonds
				}
				return fmt.Errorf("restore the run: %w", err)
			}
			if err := ledger.Diamonds(ctx, q, p, spent, -price, ledger.CalendarRestore, ref); err != nil {
				return err
			}
			p = spent
		case calendar.MendPardon:
			if _, err := q.SpendToken(ctx, sqlcdb.SpendTokenParams{PlayerID: p.ID, Token: "pardon", Qty: 1}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return ErrNoToken
				}
				return fmt.Errorf("use a pardon: %w", err)
			}
		}

		claimed, err := q.ClaimCalendarDay(ctx, sqlcdb.ClaimCalendarDayParams{
			ID: p.ID, Streak: int32(after.Streak), Today: pgtype.Date{Time: today, Valid: true},
			Pos: int16(after.Pos), Cycle: int32(after.Cycle),
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim the day: %w", err)
		}
		p = claimed

		g, err := d.grantBundle(ctx, q, &p, cal.Squares[square-1].Grant, GrantSource{
			Diamonds: ledger.DailyLogin, Gold: "daily_login", Ref: ref, ItemFrom: "reward",
		})
		if err != nil {
			return err
		}
		lines = g.Lines

		// A pardon comes with each cycle's first square, up to the most a lord
		// may hold.
		if begins && cal.PardonsPerCycle > 0 {
			held, err := tokenCounts(ctx, q, p.ID)
			if err != nil {
				return err
			}
			if give := min(cal.PardonsPerCycle, cal.PardonsMax-held["pardon"]); give > 0 {
				pardon := gameconfig.RewardBundle{Tokens: map[string]int64{"pardon": give}}
				pg, err := d.grantBundle(ctx, q, &p, pardon, GrantSource{Diamonds: ledger.DailyLogin, Ref: ref + ":pardon"})
				if err != nil {
					return err
				}
				lines = append(lines, pg.Lines...)
			}
		}
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.DailyClaims: 1})
		return nil
	})
	if err != nil {
		return nil, err
	}
	view, err := d.GetDaily(ctx, playerID)
	if err != nil {
		return nil, err
	}
	snap, err := d.GetState(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return &DailyClaim{Lines: lines, Daily: view, Snapshot: snap}, nil
}
