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
)

// ErrAlreadyClaimed is today's square already taken.
var ErrAlreadyClaimed = errors.New("you have already collected today")

// DailyView is the calendar as the player sees it.
type DailyView struct {
	// Day within the week, 1-7, that TODAY would claim.
	Day       int     `json:"day"`
	Streak    int     `json:"streak"`
	Claimable bool    `json:"claimable"`
	Reward    int64   `json:"reward"`
	Rewards   []int64 `json:"rewards"`
	Diamonds  int64   `json:"diamonds"`
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

// dailyState works out which square today is, without writing anything.
//
// The streak advances only when the last claim was YESTERDAY. Any longer gap
// starts the week over, which is what makes a seven-day calendar a streak
// rather than a counter that eventually reaches seven.
func (d Deps) dailyState(p sqlcdb.AppPlayer, now time.Time) (day int, claimable bool) {
	rewards := d.Config.Progression.DailyLogin.Rewards
	if len(rewards) == 0 {
		return 0, false
	}
	today := localDay(now, p.ResetOffsetMinutes)

	streak := int(p.DailyStreak)
	if !p.DailyClaimedOn.Valid {
		return 1, true
	}
	last := localDay(p.DailyClaimedOn.Time.UTC(), 0)
	switch {
	case !last.Before(today):
		// Already claimed today. Show the square they took, not the next one.
		if streak < 1 {
			streak = 1
		}
		return ((streak - 1) % len(rewards)) + 1, false
	case last.AddDate(0, 0, 1).Equal(today):
		streak++ // came back the very next day
	default:
		if d.Config.Progression.DailyLogin.ResetOnMiss {
			streak = 1
		} else {
			streak++
		}
	}
	return ((streak - 1) % len(rewards)) + 1, true
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
	rewards := d.Config.Progression.DailyLogin.Rewards
	day, claimable := d.dailyState(p, d.Now())

	v := &DailyView{
		Day: day, Streak: int(p.DailyStreak), Claimable: claimable,
		Rewards: rewards, Diamonds: p.Diamonds,
	}
	if day >= 1 && day <= len(rewards) {
		v.Reward = rewards[day-1]
	}
	return v, nil
}

// ClaimDaily takes today's square.
//
// Idempotent by construction rather than by checking first: the UPDATE only
// matches a row that has not already claimed on this local date, so two taps or
// two devices cannot both be paid.
func (d Deps) ClaimDaily(ctx context.Context, playerID uuid.UUID) (*DailyView, error) {
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}

		now := d.Now()
		day, claimable := d.dailyState(p, now)
		if !claimable {
			return ErrAlreadyClaimed
		}
		rewards := d.Config.Progression.DailyLogin.Rewards
		if day < 1 || day > len(rewards) {
			return ErrNothingToBuy
		}

		// The stored streak is the running count, not the square: it is what
		// lets a player see "day 23" while the calendar shows square 2.
		streak := int(p.DailyStreak) + 1
		if p.DailyClaimedOn.Valid {
			last := localDay(p.DailyClaimedOn.Time.UTC(), 0)
			if !last.AddDate(0, 0, 1).Equal(localDay(now, p.ResetOffsetMinutes)) &&
				d.Config.Progression.DailyLogin.ResetOnMiss {
				streak = 1
			}
		} else {
			streak = 1
		}

		today := localDay(now, p.ResetOffsetMinutes)
		if _, err := q.ClaimDailyLogin(ctx, sqlcdb.ClaimDailyLoginParams{
			ID: playerID, Streak: int32(streak),
			Today:    pgtype.Date{Time: today, Valid: true},
			Diamonds: rewards[day-1],
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrAlreadyClaimed
			}
			return fmt.Errorf("claim daily: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return d.GetDaily(ctx, playerID)
}
