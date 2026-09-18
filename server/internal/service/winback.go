package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Welcome back (retention.winback): a lord away three days or more finds a
// letter from the crown when they return -- gold, a Great Flask, a cart writ
// and a day of half again as much gold and experience from the moment it is
// opened (the timed lane, like any event). Away fourteen days, a second letter
// with diamonds. One welcome in each fortnight, and one per absence: the
// letter sent is stamped on the lord, and a lord seen since starts the next.

// winbackBatch bounds one run: the rest wait an hour.
const winbackBatch = 500

func sendWinbacks(ctx context.Context, d Deps, now time.Time) error {
	wb := d.Config.Retention.Winback
	if wb.AwayDays <= 0 {
		return nil
	}
	day := 24 * time.Hour
	q := sqlcdb.New(d.Pool)
	due, err := q.ListWinbackDue(ctx, sqlcdb.ListWinbackDueParams{
		AwayBefore:     now.Add(-time.Duration(wb.AwayDays) * day),
		CooldownBefore: now.Add(-time.Duration(wb.CooldownDays) * day),
		LongBefore:     now.Add(-time.Duration(wb.LongAwayDays) * day),
		MaxRows:        winbackBatch,
	})
	if err != nil {
		return fmt.Errorf("welcome back: %w", err)
	}
	sent := 0
	for _, r := range due {
		longAway := now.Sub(r.LastSeenAt) >= time.Duration(wb.LongAwayDays)*day
		// This absence already welcomed: only the long letter is left to send.
		welcomed := r.WinbackTier >= 1 && r.WinbackAt != nil && !r.WinbackAt.Before(r.LastSeenAt)
		draft, tier := MailDraft{Kind: MailWinback, Title: wb.Title, Body: wb.Body, Attachments: wb.Grant}, int16(1)
		switch {
		case welcomed && longAway:
			draft = MailDraft{Kind: MailWinback, Title: wb.LongTitle, Body: wb.LongBody, Attachments: wb.LongGrant}
			tier = 2
		case welcomed:
			continue
		case longAway:
			// Away long enough for both before the first could be sent: one
			// letter carries both.
			draft.Attachments = mergeBundles(wb.Grant, wb.LongGrant)
			draft.Title, draft.Body, tier = wb.LongTitle, wb.Body+"\n\n"+wb.LongBody, 2
		}
		draft.IdemKey = fmt.Sprintf("winback:%d:%d", r.LastSeenAt.Unix(), tier)
		err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			tq := sqlcdb.New(tx)
			if _, err := tq.MarkWinback(ctx, sqlcdb.MarkWinbackParams{
				ID: r.ID, At: &now, Tier: tier, FromTier: r.WinbackTier, FromAt: r.WinbackAt,
			}); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return nil // another run sent it
				}
				return err
			}
			_, err := d.SendMail(ctx, tq, r.ID, draft)
			return err
		})
		if err != nil {
			return fmt.Errorf("welcome back %s: %w", r.ID, err)
		}
		sent++
	}
	if d.Log != nil && sent > 0 {
		d.Log.Info("welcome-back letters sent", "letters", sent)
	}
	return nil
}

// mergeBundles is two rewards as one letter's.
func mergeBundles(a, b gameconfig.RewardBundle) gameconfig.RewardBundle {
	out := a
	out.Diamonds += b.Diamonds
	out.Gold += b.Gold
	out.XP += b.XP
	out.GoldWages += b.GoldWages
	out.XPWages += b.XPWages
	out.Favour += b.Favour
	if len(a.Tokens)+len(b.Tokens) > 0 {
		out.Tokens = map[string]int64{}
		for id, n := range a.Tokens {
			out.Tokens[id] += n
		}
		for id, n := range b.Tokens {
			out.Tokens[id] += n
		}
	}
	out.Items = append(append([]gameconfig.ItemGrant(nil), a.Items...), b.Items...)
	out.Cosmetics = append(append([]string(nil), a.Cosmetics...), b.Cosmetics...)
	out.Boosts = append(append([]gameconfig.BoostGrant(nil), a.Boosts...), b.Boosts...)
	return out
}
