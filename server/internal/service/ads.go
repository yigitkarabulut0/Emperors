package service

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/yigitkarabulut0/emperors/server/internal/ads"
	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// HERALD'S TIDINGS -- the rewarded advert (store.png's herald, commerce.ads).
//
// An advert is MONEY. The lord pays with their attention and the house is paid
// by the advertiser, so what it hands back is held to the paid rules exactly as
// a purchase is: `CheckReward(grant, true)` at publish time, which leaves
// diamonds, tokens, cosmetics and comfort, and refuses gold, experience,
// favour, gear and timed bonuses. There is no second list.
//
// THE CLIENT NEVER SAYS "I WATCHED IT". A client that could say that could say
// it a hundred times, and the diamonds it mints are the ones the store sells.
// So a watch is a TICKET first: the lord taps, the server writes a row and
// hands its id back, the SDK carries it to Google, and GOOGLE'S CALLBACK --
// signed with one of their published keys (internal/ads) -- is what turns it
// into diamonds. The reward is paid on a request that carries no session at
// all, and the signature is the only credential in it.
//
// The leashes, all counted from the rows rather than a counter that could drift
// from them: five paid a day on the lord's own day, a cooldown between them,
// one watch in flight at a time (which is what stops a tap minting tickets by
// the thousand), and a level before the herald appears at all.

var (
	// The realm has no advert to play at all.
	ErrHeraldShut = errors.New("the herald has no tidings today")
	// The realm has one, and this lord is not old enough to be told it.
	ErrHeraldEarly = errors.New("the herald calls on older lords")
	ErrHeraldSpent = errors.New("you have heard today's tidings")
	ErrHeraldSoon  = errors.New("the herald is catching his breath")
)

// Herald holds what an advert callback is checked against.
//
// Nil is legal everywhere and means the realm has no adverts: the store hides
// the section, the routes answer that it is shut, and nothing else changes.
// That is the state this server ships in, and the owner opens it by setting
// EMPERORS_ADMOB_UNIT -- not by a deploy of ours.
type Herald struct {
	// UnitID is the rewarded unit the client plays. Empty keeps the herald shut.
	UnitID  string
	KeysURL string
	Client  *http.Client
	// MaxAge is how old a callback may be; zero is the verifier's own default.
	MaxAge time.Duration

	mu        sync.RWMutex
	keys      map[int64]*ecdsa.PublicKey
	refreshed time.Time
}

// keyRefreshEvery is the soonest the key set is fetched again after a callback
// arrives signed with a key id this server does not have. A rotation is rare;
// a flood of forged key ids is not, and each one must not become a request to
// Google.
const keyRefreshEvery = 5 * time.Minute

// Open reports a herald with an advert to play and a key to check it with.
func (h *Herald) Open() bool {
	if h == nil || h.UnitID == "" {
		return false
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.keys) > 0
}

// Trust puts a key set in by hand: the dev key a local realm signs its own
// callbacks with, and what a test uses.
func (h *Herald) Trust(keys map[int64]*ecdsa.PublicKey) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.keys = keys
	h.refreshed = time.Now()
}

// Refresh fetches Google's published verifier keys.
func (h *Herald) Refresh(ctx context.Context) error {
	if h == nil {
		return nil
	}
	keys, err := ads.FetchKeys(ctx, h.Client, h.KeysURL)
	if err != nil {
		return err
	}
	h.Trust(keys)
	return nil
}

// verifier is the herald's keys, as the checker wants them.
func (h *Herald) verifier() ads.Verifier {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make(map[int64]*ecdsa.PublicKey, len(h.keys))
	for id, k := range h.keys {
		out[id] = k
	}
	return ads.Verifier{Keys: out, MaxAge: h.MaxAge}
}

// mayRefresh reports whether the key set is old enough to fetch again.
func (h *Herald) mayRefresh(now time.Time) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return now.Sub(h.refreshed) >= keyRefreshEvery
}

// HeraldView is the store's section: what an advert pays, how many are left
// today, and when the next one may be watched. The store hides the whole thing
// while `enabled` is false rather than show a plate that plays nothing -- a
// realm with no advert configured has no herald at all.
type HeraldView struct {
	Enabled bool `json:"enabled"`
	// Unlocked is this lord's own gate: the realm has an advert to play, and
	// they have reached the level it is offered at. A lord below it sees the
	// plate with its level on it, the way every other gated thing here is
	// shown -- `enabled` without `unlocked` is "not yet", not "never".
	Unlocked bool `json:"unlocked"`
	// The advert unit the client plays. Empty while the herald is shut.
	Unit string `json:"unit,omitempty"`
	// What one is worth, in the server's own words, and the figures behind them.
	Lines    []string `json:"lines,omitempty"`
	Diamonds int64    `json:"diamonds,omitempty"`
	// Today's allowance: how many are left of how many.
	Left   int `json:"left"`
	PerDay int `json:"per_day"`
	// Seconds until the next may be watched, 0 for now.
	NextIn int64 `json:"next_in,omitempty"`
	// The level the herald appears at, for a lord who has not reached it.
	UnlockLevel int `json:"unlock_level,omitempty"`
}

// AdTicket is a started watch: what the client hands the advert SDK.
type AdTicket struct {
	// Ticket is carried as AdMob's `custom_data`, and the lord as its `user_id`.
	Ticket string `json:"ticket"`
	UserID string `json:"user_id"`
	Unit   string `json:"unit"`
	// Seconds the ticket is good for.
	ExpiresIn int64 `json:"expires_in"`
}

// herald builds the store's section for one lord.
func (d Deps) herald(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) HeraldView {
	cfg := d.Config.Commerce.Ads
	v := HeraldView{PerDay: cfg.PerDay, UnlockLevel: cfg.MinLevel}
	if !d.Herald.Open() || cfg.PerDay < 1 {
		return v
	}
	// The realm has one to play, so the plate is drawn, with what an advert is
	// worth on it. Whether THIS lord may watch one yet is the next question.
	v.Enabled = true
	v.Unit = d.Herald.UnitID
	v.Diamonds = cfg.Grant.Diamonds
	v.Lines = d.rewardLines(cfg.Grant, int(p.Level))
	if int(p.Level) < cfg.MinLevel {
		return v
	}
	now := d.Now()
	day := adDayStart(p, now)
	used, err := q.CountAdWatchesPaidSince(ctx, sqlcdb.CountAdWatchesPaidSinceParams{
		PlayerID: p.ID, Since: &day,
	})
	if err != nil {
		// The section is a kindness, not the screen: a herald whose allowance
		// cannot be counted shows nothing at all for this request, rather than
		// a plate that would say the wrong number or the wrong reason.
		if d.Log != nil {
			d.Log.Warn("the herald could not be counted", "err", err)
		}
		return HeraldView{PerDay: cfg.PerDay, UnlockLevel: cfg.MinLevel}
	}
	v.Unlocked = true
	v.Left = cfg.PerDay - int(used)
	if v.Left < 0 {
		v.Left = 0
	}
	if last, err := q.LastAdWatchPaidAt(ctx, p.ID); err == nil && cfg.CooldownMinutes > 0 {
		next := last.Add(time.Duration(cfg.CooldownMinutes) * time.Minute)
		v.NextIn = secondsUntil(next, now)
	}
	return v
}

// adDayStart is the beginning of this lord's own day, which is where the
// allowance is counted from -- the day the refills and the quests use.
func adDayStart(p sqlcdb.AppPlayer, now time.Time) time.Time {
	return localDay(now, p.ResetOffsetMinutes)
}

// StartAdWatch hands out a ticket for one advert.
//
// NOT sequenced. Nothing of the lord's own moves -- no gold, no energy, no
// diamonds -- and nothing is owed until Google says the advert was watched. The
// client adopts nothing from this answer.
func (d Deps) StartAdWatch(ctx context.Context, playerID uuid.UUID) (*AdTicket, error) {
	if !d.Herald.Open() {
		return nil, ErrHeraldShut
	}
	cfg := d.Config.Commerce.Ads
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("herald: %w", err)
	}
	if cfg.PerDay < 1 {
		return nil, ErrHeraldShut
	}
	if int(p.Level) < cfg.MinLevel {
		return nil, fmt.Errorf("%w: level %d", ErrHeraldEarly, cfg.MinLevel)
	}
	now := d.Now()

	day := adDayStart(p, now)
	used, err := q.CountAdWatchesPaidSince(ctx, sqlcdb.CountAdWatchesPaidSinceParams{
		PlayerID: playerID, Since: &day,
	})
	if err != nil {
		return nil, fmt.Errorf("today's tidings: %w", err)
	}
	if int(used) >= cfg.PerDay {
		return nil, ErrHeraldSpent
	}
	if cfg.CooldownMinutes > 0 {
		last, err := q.LastAdWatchPaidAt(ctx, playerID)
		if err != nil {
			return nil, fmt.Errorf("the herald's breath: %w", err)
		}
		if next := last.Add(time.Duration(cfg.CooldownMinutes) * time.Minute); next.After(now) {
			return nil, fmt.Errorf("%w: %d seconds", ErrHeraldSoon, secondsUntil(next, now))
		}
	}
	// One at a time. A ticket already in flight is handed back rather than a
	// second one minted: a tap that lost its answer must not cost the lord the
	// advert they are already watching.
	if live, err := q.LiveAdWatch(ctx, sqlcdb.LiveAdWatchParams{PlayerID: playerID, Now: now}); err == nil {
		return &AdTicket{
			Ticket: live.ID.String(), UserID: playerID.String(), Unit: live.Unit,
			ExpiresIn: secondsUntil(live.ExpiresAt, now),
		}, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("the watch in flight: %w", err)
	}

	row, err := q.StartAdWatch(ctx, sqlcdb.StartAdWatchParams{
		PlayerID: playerID, Unit: d.Herald.UnitID, Now: now,
		ExpiresAt: now.Add(time.Duration(cfg.TicketMinutes) * time.Minute),
	})
	if err != nil {
		return nil, fmt.Errorf("start a watch: %w", err)
	}
	return &AdTicket{
		Ticket: row.ID.String(), UserID: playerID.String(), Unit: row.Unit,
		ExpiresIn: secondsUntil(row.ExpiresAt, now),
	}, nil
}

// CreditAdWatch pays for one watched advert, from Google's own callback.
//
// `raw` is the request's query string exactly as it arrived: what was signed is
// the bytes, not the fields, so it must not be parsed and rebuilt on the way
// here (internal/ads says why, and a test in that package proves it).
//
// Quiet about everything: a callback that cannot be paid is answered 200 all
// the same, because Google retries a failure for hours and a forged one must
// not learn whether it guessed a real ticket.
func (d Deps) CreditAdWatch(ctx context.Context, raw string) error {
	if !d.Herald.Open() {
		return ErrHeraldShut
	}
	now := d.Now()
	call, err := d.Herald.verifier().Verify(raw, now)
	if errors.Is(err, ads.ErrUnknownKey) && d.Herald.mayRefresh(now) {
		// What a key rotation looks like from here. Fetch once, then judge it
		// again; if it still fails, it was not a rotation.
		if rerr := d.Herald.Refresh(ctx); rerr == nil {
			call, err = d.Herald.verifier().Verify(raw, now)
		}
	}
	if err != nil {
		return err
	}

	ticket, err := uuid.Parse(call.CustomData)
	if err != nil {
		return fmt.Errorf("%w: the ticket is not an id", ads.ErrInvalid)
	}
	lord, err := uuid.Parse(call.UserID)
	if err != nil {
		return fmt.Errorf("%w: the lord is not an id", ads.ErrInvalid)
	}
	cfg := d.Config.Commerce.Ads

	return db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		watch, err := q.LockAdWatch(ctx, ticket)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: no such watch", ads.ErrInvalid)
			}
			return fmt.Errorf("the watch: %w", err)
		}
		// The ticket names a lord, and the callback names one. A callback that
		// pointed a stranger's watch at another lord's purse is the one thing
		// this check exists for.
		if watch.PlayerID != lord {
			return fmt.Errorf("%w: the watch belongs to another lord", ads.ErrInvalid)
		}
		if watch.PaidAt != nil {
			return nil // already paid; Google is retrying a success
		}
		if !watch.ExpiresAt.After(now) {
			return fmt.Errorf("%w: the ticket has expired", ads.ErrStale)
		}

		p, err := q.LockPlayer(ctx, lord)
		if err != nil {
			return fmt.Errorf("lock player: %w", err)
		}
		// The allowance is judged again HERE, inside the lock: the check at the
		// tap was a courtesy, and this is the one that counts.
		day := adDayStart(p, now)
		used, err := q.CountAdWatchesPaidSince(ctx, sqlcdb.CountAdWatchesPaidSinceParams{
			PlayerID: lord, Since: &day,
		})
		if err != nil {
			return fmt.Errorf("today's tidings: %w", err)
		}
		if int(used) >= cfg.PerDay {
			return ErrHeraldSpent
		}

		paid, err := q.PayAdWatch(ctx, sqlcdb.PayAdWatchParams{
			TransactionID: &call.TransactionID, Now: &now,
			Diamonds: cfg.Grant.Diamonds, KeyID: pgtype.Int8{Int64: call.KeyID, Valid: true},
			ID: ticket,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil // another callback paid it between the lock and here
			}
			return fmt.Errorf("pay the watch: %w", err)
		}

		// An advert is money, so it is granted as a paid reward is: the same
		// one path, with the paid rules checked again at the moment of grant.
		if _, err := d.grantBundle(ctx, q, &p, cfg.Grant, GrantSource{
			Diamonds: ledger.Advert, Gold: "advert", ItemFrom: "advert",
			Ref: "advert:" + call.TransactionID, Paid: true,
		}); err != nil {
			return err
		}
		if d.Log != nil {
			d.Log.Info("the herald paid", "lord", lord, "diamonds", paid.Diamonds,
				"unit", paid.Unit, "key", call.KeyID)
		}
		return nil
	})
}

// AdWatchKeep is how long a paid watch is kept. It is the audit trail behind a
// diamond ledger row, so it outlives the day it was watched in by a season.
//
// Exported because the panel's desk must not offer to read a window the table
// no longer holds: a year's takings beside three months of adverts would read
// as adverts having stopped (internal/admin/billing.go).
const AdWatchKeep = 90 * 24 * time.Hour

// purgeAdWatches sweeps tickets nobody came back for, and payments old enough
// to be history.
func purgeAdWatches(ctx context.Context, d Deps, now time.Time) error {
	keep := now.Add(-AdWatchKeep)
	n, err := sqlcdb.New(d.Pool).PurgeAdWatches(ctx, sqlcdb.PurgeAdWatchesParams{
		Now: now, KeepBefore: &keep,
	})
	if err != nil {
		return fmt.Errorf("purge ad watches: %w", err)
	}
	if d.Log != nil && n > 0 {
		d.Log.Info("the herald's old tickets swept", "rows", n)
	}
	return nil
}
