package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// ScheduledJobs is every job the server runs, in the order a tick runs them.
func ScheduledJobs() []Job {
	return []Job{
		{
			// Kingdom reputation decays once per UTC day, so a realm that stopped
			// playing stops holding rank. Never retried: a missed day is a rounding
			// error against a 2% rate, and running it twice would not be.
			Name: "reputation_decay", Period: DailyUTC(0), Lease: 5 * time.Minute,
			Run: decayReputation,
		},
		{
			// Ranks, often enough to feel live and rarely enough to cost nothing.
			Name: "leaderboards", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run: func(ctx context.Context, d Deps, _ time.Time) error {
				return d.RefreshLeaderboards(ctx)
			},
		},
		{
			// Letters thrown away, or left unclaimed past their expiry, are deleted
			// once the keep window has passed too.
			Name: "mail_purge", Period: DailyUTC(4), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         purgeMail,
		},
		{
			// App Store notifications whose first attempt failed, tried again
			// with a growing wait for 72 hours after they arrived.
			Name: "iap_notifications", Period: Every(time.Minute), Lease: 50 * time.Second,
			RetryOnFail: true,
			Run:         retryNotifications,
		},
		{
			// A deleted account's diamond history, 90 days after it left. The
			// deleted_accounts row stays, so a later refund still knows the id.
			Name: "deleted_ledger_purge", Period: DailyUTC(4), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         purgeDeletedLedger,
		},
		{
			// The client's events after 180 days; the days players played after
			// 400, which keeps a year of retention with a month to spare.
			Name: "analytics_purge", Period: DailyUTC(4), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         purgeAnalytics,
		},
		{
			// Pays both sides for every friend who reached the level (referral.go).
			Name: "referral_rewards", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run:         payReferrals,
		},
		{
			// Wrong promo codes older than a day: the hourly allowance only ever
			// looks back an hour.
			Name: "promo_failures_purge", Period: DailyUTC(4), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         purgePromoFailures,
		},
		{
			// The panel's daily figures, rolled up for yesterday and the two days
			// before it, so a refund or a delivery that lands late is counted on
			// its own day (migration 00039).
			Name: "kpi_rollup", Period: DailyUTC(1), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         rollupKPIs,
		},
		{
			// A welcome back for every lord away long enough, and a second letter
			// past the long absence (winback.go). Hourly, so a lord who returns
			// finds it however the hours fell.
			Name: "winback", Period: Every(time.Hour), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         sendWinbacks,
		},
		{
			// Writes down the hour running and the next as the roll has them,
			// so a publish mid-hour changes nothing running or announced; keeps
			// two days of lords' uses of the hours (liveops.go).
			Name: "hourly_events", Period: Every(time.Minute), Lease: 50 * time.Second,
			RetryOnFail: true,
			Run:         freezeHours,
		},
		{
			// Closes every festival that has ended: its places paid by letter,
			// with what each lord left unclaimed (festival.go).
			Name: "festivals_close", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run:         closeFestivals,
		},
		{
			// Pays the week's boards once the UTC week has turned, and a
			// season's boards, nobility and leftover Charters once it has ended
			// (boards.go). After the leaderboards, so a season's last refresh
			// is not raced by its close.
			Name: "boards_close", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         closeBoards,
		},
		{
			// Rekabet: bounties past their forty-eight hours give what the
			// escrow still holds back to the lord who set them, and the fee
			// stays burned (bounty.go). Each refund is its own transaction, so
			// one that cannot be written never holds up the rest.
			Name: "bounty_expiry", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run:         expireBounties,
		},
		{
			// The Throne, once the UTC week has turned: the kingdom that gained
			// the most renown in it crowns its king (throne.go). There is no
			// weekly Period helper and there should not be one -- Period says
			// when a job may RUN, and which week has been settled is a
			// different fact that belongs in admin.period_closes, where
			// boards_close keeps it. A weekly helper would make a job that
			// missed its week skip the week entirely.
			Name: "throne_settle", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         settleThrone,
		},
		{
			// The lists' half reset at a season boundary (arena.go). A lord who
			// fights before this runs is rolled on the way in by UpsertArena,
			// and this is then a no-op for them.
			Name: "arena_reset", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         resetArenaSeason,
		},
		{
			// Krallik Boss: a beast in front of every kingdom whose window has
			// come round (boss.go). Ten minutes, because a cycle is two days
			// and nobody is waiting on the minute -- and because the insert is
			// refused by a unique index rather than by this job's timing.
			Name: "boss_cycle", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         raiseBosses,
		},
		{
			// The chests of every cycle that is over -- the window shut, or the
			// beast down -- by letter (boss.go). Sooner than the raising,
			// because a kingdom that has just killed something is watching.
			Name: "boss_settle", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run:         settleBosses,
		},
		{
			// Krallik Savaslari: the week's pairs, drawn on the balance's
			// evening (war.go). Claimed in admin.period_closes, as the Throne
			// is, so the week is drawn once however often this runs.
			Name: "war_draw", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         drawWars,
		},
		{
			// And the purse, once the war's days are over (war.go).
			Name: "war_settle", Period: Every(10 * time.Minute), Lease: 9 * time.Minute,
			RetryOnFail: true,
			Run:         settleWars,
		},
		{
			// Once per database: the lifetime counters raised to what the
			// records kept before them show (achievements.go).
			Name: "deeds_backfill", Period: func(time.Time) string { return "wave4" }, Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         backfillLifeDeeds,
		},
		{
			// Herald's Tidings: tickets nobody came back from, and payments old
			// enough to be history (ads.go). A watch is written at the tap and
			// paid by Google's callback, so the unfinished ones are the many.
			Name: "ad_watch_purge", Period: DailyUTC(4), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run:         purgeAdWatches,
		},
		{
			// Sosyal: the hall keeps what social.json says and no more. A hall
			// that kept everything would be a slow query and a subpoena target;
			// one that kept nothing would leave every report unreadable
			// (chat.go). Hourly is often enough for a rule measured in days.
			Name: "chat_sweep", Period: Every(time.Hour), Lease: 10 * time.Minute,
			RetryOnFail: true,
			Run: func(ctx context.Context, d Deps, now time.Time) error {
				n, err := d.sweepChat(ctx)
				if err == nil && n > 0 && d.Log != nil {
					d.Log.Info("the halls were swept", "lines", n)
				}
				return err
			},
		},
		{
			// Takes off what a lord wears but no longer holds -- a patron's frame
			// whose month ran out with no notice from Apple -- so every list of
			// other lords, which reads the worn columns as they are, stays true.
			Name: "cosmetics_lapse", Period: Every(5 * time.Minute), Lease: 4 * time.Minute,
			RetryOnFail: true,
			Run: func(ctx context.Context, d Deps, now time.Time) error {
				n, err := d.unwearLapsed(ctx, sqlcdb.New(d.Pool), nil, now)
				if err == nil && n > 0 && d.Log != nil {
					d.Log.Info("lapsed cosmetics taken off", "lords", n)
				}
				return err
			},
		},
	}
}

// How long what outlives its moment is kept.
const (
	deletedLedgerKeep = 90 * 24 * time.Hour
	eventsKeep        = 180 * 24 * time.Hour
	playerDaysKeep    = 400 * 24 * time.Hour
)

func purgeDeletedLedger(ctx context.Context, d Deps, now time.Time) error {
	n, err := sqlcdb.New(d.Pool).PurgeDeletedLedger(ctx, now.Add(-deletedLedgerKeep))
	if err != nil {
		return fmt.Errorf("purge deleted ledger: %w", err)
	}
	if d.Log != nil && n > 0 {
		d.Log.Info("deleted accounts' ledger purged", "rows", n)
	}
	return nil
}

func purgeAnalytics(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	events, err := q.PurgeEvents(ctx, now.Add(-eventsKeep))
	if err != nil {
		return fmt.Errorf("purge events: %w", err)
	}
	days, err := q.PurgePlayerDays(ctx, pgtype.Date{Time: now.Add(-playerDaysKeep).UTC(), Valid: true})
	if err != nil {
		return fmt.Errorf("purge player days: %w", err)
	}
	if d.Log != nil && events+days > 0 {
		d.Log.Info("analytics purged", "events", events, "days", days)
	}
	return nil
}

// kpiDays is how many finished days each kpi_rollup run writes again.
const kpiDays = 3

func rollupKPIs(ctx context.Context, d Deps, now time.Time) error {
	q := sqlcdb.New(d.Pool)
	today := now.UTC().Truncate(24 * time.Hour)
	for i := 1; i <= kpiDays; i++ {
		day := today.AddDate(0, 0, -i)
		if err := q.RollupKPIDay(ctx, pgtype.Date{Time: day, Valid: true}); err != nil {
			return fmt.Errorf("kpi %s: %w", day.Format("2006-01-02"), err)
		}
	}
	return nil
}

func purgeMail(ctx context.Context, d Deps, now time.Time) error {
	keep := time.Duration(d.Config.Rewards.Mail.PurgeAfterDays) * 24 * time.Hour
	n, err := sqlcdb.New(d.Pool).PurgeMail(ctx, now.Add(-keep))
	if err != nil {
		return fmt.Errorf("purge mail: %w", err)
	}
	if d.Log != nil && n > 0 {
		d.Log.Info("mail purged", "letters", n)
	}
	return nil
}

// decayReputation applies the day's decay.
//
// The day is also claimed in server_info, as it was before the job runner
// existed: a database restored from before a deploy, or a job_runs row cleared by
// hand, still cannot decay the same day twice.
func decayReputation(ctx context.Context, d Deps, now time.Time) error {
	bp := d.Config.Kingdoms.Reputation.DecayBPPerDay
	if bp <= 0 {
		return nil
	}
	day := now.UTC().Format("2006-01-02")
	q := sqlcdb.New(d.Pool)
	if _, err := q.ClaimDecayDay(ctx, day); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // already done today
		}
		return fmt.Errorf("claim the decay day: %w", err)
	}
	if err := q.DecayReputation(ctx, bp); err != nil {
		return fmt.Errorf("decay reputation: %w", err)
	}
	if d.Log != nil {
		d.Log.Info("reputation decayed", "day", day, "bp", bp)
	}
	return nil
}
