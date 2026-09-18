package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/deeds"
	"github.com/yigitkarabulut0/emperors/server/internal/game/economy"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/ledger"
)

// Kinds of letter. They are the mail table's CHECK constraint, in Go.
const (
	MailSystem       = "system"
	MailAdmin        = "admin"
	MailCompensation = "compensation"
	MailGift         = "gift"
	MailPromo        = "promo"
	MailReferral     = "referral"
	MailWinback      = "winback"
	// A board's prize, when its week or season closes (boards.go).
	MailBoard = "board"
	// Rekabet (Wave 5). MailBounty carries a price refunded when a bounty
	// expires unclaimed and the word that one was collected; MailThrone crowns
	// an emperor and his court.
	MailArena  = "arena"
	MailBounty = "bounty"
	MailThrone = "throne"
	// Krallik Boss ve Savaslari (Wave 8). MailBoss carries a cycle's chests to
	// everyone who raised a sword at the beast; MailWar carries the week's
	// purse to both sides, because a war nobody dares enter is a war nobody
	// has.
	MailBoss = "boss"
	MailWar  = "war"
)

var (
	ErrMailExpired = errors.New("that letter has expired")
	ErrMailClaimed = errors.New("that letter has already been opened")
	ErrMailBad     = errors.New("that letter is not valid")
	// ErrMailKeep is throwing away a letter that still has something in it.
	ErrMailKeep = errors.New("claim what the letter carries before throwing it away")
)

// MailDraft is one letter to send.
type MailDraft struct {
	Kind        string
	Sender      string
	Title       string
	Body        string
	Attachments gameconfig.RewardBundle
	// Makes the send idempotent: the same key to the same player delivers once.
	IdemKey string
	// Zero is the balance's default expiry from now.
	ExpiresAt time.Time
}

// SendMail writes one letter through q -- the caller's transaction, or the pool.
// It reports false when the idempotency key had already delivered it.
func (d Deps) SendMail(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID, m MailDraft) (bool, error) {
	if err := d.checkDraft(m); err != nil {
		return false, err
	}
	raw, err := json.Marshal(m.Attachments)
	if err != nil {
		return false, fmt.Errorf("encode attachments: %w", err)
	}
	if m.Sender == "" {
		m.Sender = "The Crown"
	}
	expires := m.ExpiresAt
	if expires.IsZero() {
		expires = d.Now().Add(time.Duration(d.Config.Rewards.Mail.DefaultExpiryDays) * 24 * time.Hour)
	}
	if _, err := q.InsertMail(ctx, sqlcdb.InsertMailParams{
		PlayerID: playerID, Kind: m.Kind, Sender: m.Sender, Title: m.Title, Body: m.Body,
		Attachments: raw, IdemKey: nilIfEmpty(m.IdemKey), ExpiresAt: expires,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil // already delivered under this key
		}
		return false, fmt.Errorf("send mail: %w", err)
	}
	return true, nil
}

// checkDraft refuses a letter that could not be delivered or claimed.
func (d Deps) checkDraft(m MailDraft) error {
	switch m.Kind {
	case MailSystem, MailAdmin, MailCompensation, MailGift, "largesse", "referral", "promo",
		"purchase", "kingdom", "event", "season", MailWinback, MailBoard,
		MailArena, MailBounty, MailThrone, MailBoss, MailWar:
	default:
		return fmt.Errorf("%w: unknown kind %q", ErrMailBad, m.Kind)
	}
	if n := len([]rune(m.Title)); n < 1 || n > 80 {
		return fmt.Errorf("%w: the title must be 1 to 80 characters", ErrMailBad)
	}
	if len([]rune(m.Body)) > 2000 {
		return fmt.Errorf("%w: the body is over 2000 characters", ErrMailBad)
	}
	if problems := d.Config.CheckReward(m.Attachments, false); len(problems) > 0 {
		return fmt.Errorf("%w: %s", ErrRewardInvalid, strings.Join(problems, "; "))
	}
	return nil
}

// MailLetter is one letter in the inbox, with what it carries already written
// out for this player.
type MailLetter struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Sender    string `json:"sender"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
	// Seconds until an unclaimed letter is gone. Zero once claimed.
	ExpiresIn int64 `json:"expires_in"`
	Read      bool  `json:"read"`
	Claimed   bool  `json:"claimed"`
	// There is something in it, and it can still be taken.
	Claimable bool           `json:"claimable"`
	Lines     []rewards.Line `json:"lines"`
}

// MailView is the inbox.
type MailView struct {
	Mail []MailLetter `json:"mail"`
	// Letters unread, or read with something still to claim.
	Waiting int `json:"waiting"`
}

// materializeMail gives the player their copy of every 'all' letter sent since
// they last looked. One indexed read when there is nothing new.
func (d Deps) materializeMail(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) error {
	now := d.Now()
	latest, err := q.LatestAllBroadcast(ctx, now)
	if err != nil {
		return fmt.Errorf("latest broadcast: %w", err)
	}
	if latest <= p.MailBcSeen {
		return nil
	}
	if _, err := q.MaterializeBroadcasts(ctx, sqlcdb.MaterializeBroadcastsParams{PlayerID: p.ID, Now: now}); err != nil {
		return fmt.Errorf("materialise broadcasts: %w", err)
	}
	return q.SetMailBroadcastSeen(ctx, sqlcdb.SetMailBroadcastSeenParams{ID: p.ID, Seen: latest})
}

// GetMail returns the inbox, newest first.
func (d Deps) GetMail(ctx context.Context, playerID uuid.UUID) (*MailView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("mail: %w", err)
	}
	if err := d.materializeMail(ctx, q, p); err != nil {
		// The letters already delivered are still worth showing.
		d.logSoftStep("mail broadcast", err)
	}
	now := d.Now()
	rows, err := q.ListMail(ctx, sqlcdb.ListMailParams{
		PlayerID: playerID, Now: now, Lim: int32(d.Config.Rewards.Mail.InboxLimit),
	})
	if err != nil {
		return nil, fmt.Errorf("list mail: %w", err)
	}

	// Wages are worth what they pay at this player's level, so the lines need the
	// player's permanent bonuses -- read once, and only if some letter has wages.
	var bonuses *economy.Bonuses
	view := &MailView{Mail: make([]MailLetter, 0, len(rows))}
	for _, r := range rows {
		var b gameconfig.RewardBundle
		_ = json.Unmarshal(r.Attachments, &b)
		if (b.GoldWages > 0 || b.XPWages > 0) && bonuses == nil {
			eff, err := d.loadEffects(ctx, q, p)
			if err != nil {
				return nil, err
			}
			bonuses = &eff.Bonuses
		}
		var bon economy.Bonuses
		if bonuses != nil {
			bon = *bonuses
		}
		l := MailLetter{
			ID: r.ID, Kind: r.Kind, Sender: r.Sender, Title: r.Title, Body: r.Body,
			CreatedAt: r.CreatedAt.UTC().Format(time.RFC3339),
			Read:      r.ReadAt != nil, Claimed: r.ClaimedAt != nil,
			Lines: rewards.Lines(d.Config, b, rewards.Resolve(d.Config, b, int(p.Level), bon)),
		}
		if l.Lines == nil {
			l.Lines = []rewards.Line{}
		}
		if !l.Claimed {
			l.ExpiresIn = int64(r.ExpiresAt.Sub(now) / time.Second)
			l.Claimable = !b.Empty()
		}
		if !l.Read || l.Claimable {
			view.Waiting++
		}
		view.Mail = append(view.Mail, l)
	}
	return view, nil
}

// ReadMail marks a letter read.
func (d Deps) ReadMail(ctx context.Context, playerID uuid.UUID, id int64) error {
	return sqlcdb.New(d.Pool).MarkMailRead(ctx, sqlcdb.MarkMailReadParams{ID: id, PlayerID: playerID})
}

// MailClaim is what one claim delivered.
type MailClaim struct {
	Granted  Granted   `json:"granted"`
	Snapshot *Snapshot `json:"snapshot"`
}

// ClaimMail takes what a letter carries.
//
// No action_seq: a letter is claimed once by construction (the WHERE on its
// row), and a letter arriving must never move the sequence the client's queued
// collects are counting on.
func (d Deps) ClaimMail(ctx context.Context, playerID uuid.UUID, id int64) (*MailClaim, error) {
	var res MailClaim
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		g, err := d.claimOne(ctx, q, &p, id)
		if err != nil {
			return err
		}
		res.Granted = g
		d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.MailClaims: 1, deeds.XP: g.XP})
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// claimOne claims one letter inside the caller's transaction.
func (d Deps) claimOne(ctx context.Context, q *sqlcdb.Queries, p *sqlcdb.AppPlayer, id int64) (Granted, error) {
	row, err := q.ClaimMailRow(ctx, sqlcdb.ClaimMailRowParams{ID: id, PlayerID: p.ID, Now: d.Now()})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return Granted{}, fmt.Errorf("claim mail: %w", err)
		}
		// Say why, rather than a bare no.
		m, gerr := q.GetMail(ctx, sqlcdb.GetMailParams{ID: id, PlayerID: p.ID})
		switch {
		case gerr != nil || m.DeletedAt != nil:
			return Granted{}, ErrNotFound
		case m.ClaimedAt != nil:
			return Granted{}, ErrMailClaimed
		default:
			return Granted{}, ErrMailExpired
		}
	}
	var b gameconfig.RewardBundle
	if err := json.Unmarshal(row.Attachments, &b); err != nil {
		return Granted{}, fmt.Errorf("letter %d attachments: %w", id, err)
	}
	return d.grantBundle(ctx, q, p, b, GrantSource{
		Diamonds: ledger.Mail, Gold: "mail", Ref: fmt.Sprintf("mail:%d", id), ItemFrom: "mail",
	})
}

// MailClaimAll is what CLAIM ALL delivered, and what it had to leave.
type MailClaimAll struct {
	Claimed  []int64        `json:"claimed"`
	Skipped  []MailSkip     `json:"skipped"`
	Lines    []rewards.Line `json:"lines"`
	Snapshot *Snapshot      `json:"snapshot"`
}

// MailSkip is a letter CLAIM ALL could not open, and why.
type MailSkip struct {
	ID     int64  `json:"id"`
	Reason string `json:"reason"`
}

// ClaimAllMail opens every claimable letter it can, oldest first.
//
// Each letter is claimed in its own savepoint: a letter whose gear will not fit
// in the armory is left for later, unclaimed, and the rest are still paid.
func (d Deps) ClaimAllMail(ctx context.Context, playerID uuid.UUID) (*MailClaimAll, error) {
	res := MailClaimAll{Claimed: []int64{}, Skipped: []MailSkip{}, Lines: []rewards.Line{}}
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		p, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		ids, err := q.ListClaimableMail(ctx, sqlcdb.ListClaimableMailParams{
			PlayerID: playerID, Now: d.Now(), Lim: int32(d.Config.Rewards.Mail.ClaimAllMax),
		})
		if err != nil {
			return fmt.Errorf("claimable mail: %w", err)
		}
		var xp int64
		for _, id := range ids {
			sp, err := tx.Begin(ctx)
			if err != nil {
				return fmt.Errorf("savepoint: %w", err)
			}
			before := p
			g, err := d.claimOne(ctx, sqlcdb.New(sp), &p, id)
			if err != nil {
				_ = sp.Rollback(ctx)
				p = before
				reason := "error"
				switch {
				case errors.Is(err, ErrInventoryFull):
					reason = "inventory_full"
				case errors.Is(err, ErrMailExpired):
					reason = "expired"
				default:
					d.logSoftStep("claim-all letter", err)
				}
				res.Skipped = append(res.Skipped, MailSkip{ID: id, Reason: reason})
				continue
			}
			if err := sp.Commit(ctx); err != nil {
				return fmt.Errorf("release savepoint: %w", err)
			}
			res.Claimed = append(res.Claimed, id)
			res.Lines = append(res.Lines, g.Lines...)
			xp += g.XP
		}
		if len(res.Claimed) > 0 {
			d.recordDeeds(ctx, tx, p, deeds.Deeds{deeds.MailClaims: int64(len(res.Claimed)), deeds.XP: xp})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	res.Snapshot, err = d.GetState(ctx, playerID)
	return &res, err
}

// DeleteMail throws a letter away, once there is nothing left in it to take.
func (d Deps) DeleteMail(ctx context.Context, playerID uuid.UUID, id int64) error {
	n, err := sqlcdb.New(d.Pool).DeleteMail(ctx, sqlcdb.DeleteMailParams{ID: id, PlayerID: playerID, Now: d.Now()})
	if err != nil {
		return fmt.Errorf("delete mail: %w", err)
	}
	if n == 0 {
		// Still carrying something, or not theirs. Throwing away a reward by a
		// slip of the thumb is the one thing this must not allow.
		return ErrMailKeep
	}
	return nil
}

// mailWaiting is the heartbeat's count: letters unread or still to claim.
func (d Deps) mailWaiting(ctx context.Context, q *sqlcdb.Queries, p sqlcdb.AppPlayer) (int, error) {
	if err := d.materializeMail(ctx, q, p); err != nil {
		d.logSoftStep("mail broadcast", err)
	}
	n, err := q.CountMailWaiting(ctx, sqlcdb.CountMailWaitingParams{PlayerID: p.ID, Now: d.Now()})
	return int(n), err
}
