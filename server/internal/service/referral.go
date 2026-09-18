package service

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Bringing a friend. Every lord has a code; a friend enters it within their
// first week, before the reward level, and when they reach it both are paid,
// by letter. Refused: a lord's own code, a code entered on a phone its owner
// plays on, an inviter whose account is younger than the minimum, and an
// inviter past their day's links or their lifetime of rewards.

// referralAlphabet has no 0/O or 1/I/L, so a code read aloud is typed right.
const referralAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// ReferralView is a lord's code and the friends it brought.
type ReferralView struct {
	Code string `json:"code"`
	// What each side is paid, and at which level.
	RewardLevel     int              `json:"reward_level"`
	InviterDiamonds int64            `json:"inviter_diamonds"`
	InviteeDiamonds int64            `json:"invitee_diamonds"`
	Friends         []ReferralFriend `json:"friends"`
	Rewarded        int              `json:"rewarded"`
	RewardsLeft     int              `json:"rewards_left"`
	// Whether this lord may still enter a friend's code, and until when.
	CanClaim  bool   `json:"can_claim"`
	ClaimInS  int64  `json:"claim_in,omitempty"`
	ClaimedBy string `json:"claimed_by,omitempty"`
}

// ReferralFriend is one friend a lord brought, with their face and their
// look, as every list of lords shows them.
type ReferralFriend struct {
	Name     string `json:"name"`
	Avatar   string `json:"avatar"`
	Level    int    `json:"level"`
	Rewarded bool   `json:"rewarded"`
	Look
}

func newReferralCode() (string, error) {
	b := make([]byte, 6)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(referralAlphabet))))
		if err != nil {
			return "", err
		}
		b[i] = referralAlphabet[n.Int64()]
	}
	return string(b), nil
}

// referralCode returns a lord's code, making it the first time.
func (d Deps) referralCode(ctx context.Context, q *sqlcdb.Queries, playerID uuid.UUID) (string, error) {
	row, err := q.GetReferralCode(ctx, playerID)
	if err == nil {
		return row.Code, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("referral code: %w", err)
	}
	for i := 0; i < 8; i++ {
		code, err := newReferralCode()
		if err != nil {
			return "", err
		}
		row, err := q.InsertReferralCode(ctx, sqlcdb.InsertReferralCodeParams{PlayerID: playerID, Code: code})
		if err == nil {
			return row.Code, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("make referral code: %w", err)
		}
		// Taken by another lord, or this lord's was made a moment ago.
		if row, err := q.GetReferralCode(ctx, playerID); err == nil {
			return row.Code, nil
		}
	}
	return "", errors.New("no free referral code after 8 tries")
}

// GetReferral is a lord's code and the friends it brought.
func (d Deps) GetReferral(ctx context.Context, playerID uuid.UUID) (*ReferralView, error) {
	q := sqlcdb.New(d.Pool)
	p, err := q.GetPlayerByID(ctx, playerID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	cfg := d.Config.Rewards.Referral
	code, err := d.referralCode(ctx, q, playerID)
	if err != nil {
		return nil, err
	}
	now := d.Now()
	v := &ReferralView{Code: code, RewardLevel: cfg.RewardLevel, InviterDiamonds: cfg.InviterDiamonds,
		InviteeDiamonds: cfg.InviteeDiamonds, Friends: []ReferralFriend{}}
	rows, err := q.ListReferralsByInviter(ctx, playerID)
	if err != nil {
		return nil, fmt.Errorf("friends: %w", err)
	}
	for _, r := range rows {
		v.Friends = append(v.Friends, ReferralFriend{Name: r.DisplayName, Avatar: r.Avatar, Level: int(r.Level),
			Rewarded: r.RewardedAt != nil,
			Look:     lookOf(d.Config, r.CosFrame, r.CosTitle, r.CosColor, r.CosCrest, r.VipPoints)})
		if r.RewardedAt != nil {
			v.Rewarded++
		}
	}
	v.RewardsLeft = cfg.RewardsTotal - v.Rewarded
	if v.RewardsLeft < 0 {
		v.RewardsLeft = 0
	}
	if link, err := q.GetReferral(ctx, playerID); err == nil {
		if inviter, err := q.GetPlayerByID(ctx, link.InviterID); err == nil {
			v.ClaimedBy = inviter.DisplayName
		}
	} else if deadline := p.CreatedAt.AddDate(0, 0, cfg.ClaimDays); now.Before(deadline) && int(p.Level) < cfg.RewardLevel {
		v.CanClaim = true
		v.ClaimInS = int64(deadline.Sub(now) / time.Second)
	}
	return v, nil
}

// ClaimReferral links this lord to the friend who brought them.
func (d Deps) ClaimReferral(ctx context.Context, playerID uuid.UUID, code, device string) (*ReferralView, error) {
	if !validDevice(device) {
		return nil, ErrNoDevice
	}
	code = NormalizePromo(code)
	cfg := d.Config.Rewards.Referral
	now := d.Now()
	hash := d.deviceHash(device)
	err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		q := sqlcdb.New(tx)
		me, err := q.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		if _, err := q.GetReferral(ctx, playerID); err == nil {
			return ErrReferralClosed
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("referral: %w", err)
		}
		if now.After(me.CreatedAt.AddDate(0, 0, cfg.ClaimDays)) || int(me.Level) >= cfg.RewardLevel {
			return ErrReferralClosed
		}
		inviter, err := q.PlayerByReferralCode(ctx, code)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrReferralCode
		}
		if err != nil {
			return fmt.Errorf("inviter: %w", err)
		}
		if inviter.ID == me.ID {
			return ErrReferralSelf
		}
		if inviter.IsBot || now.Sub(inviter.CreatedAt) < time.Duration(cfg.InviterMinHours)*time.Hour {
			return ErrReferralCode
		}
		// A friend on the inviter's own phone is the inviter.
		shared, err := q.PlayedOnDevice(ctx, sqlcdb.PlayedOnDeviceParams{PlayerID: inviter.ID, DeviceHash: hash})
		if err != nil {
			return fmt.Errorf("devices: %w", err)
		}
		if shared {
			return ErrReferralSelf
		}
		counts, err := q.CountReferralLinks(ctx, sqlcdb.CountReferralLinksParams{
			InviterID: inviter.ID, Since: now.Add(-24 * time.Hour),
		})
		if err != nil {
			return fmt.Errorf("links: %w", err)
		}
		if int(counts.Today) >= cfg.LinksPerDay || int(counts.Rewarded) >= cfg.RewardsTotal {
			return ErrReferralLimit
		}
		if _, err := q.InsertReferral(ctx, sqlcdb.InsertReferralParams{
			InviteeID: me.ID, InviterID: inviter.ID, DeviceHash: hash,
		}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrReferralClosed
			}
			return fmt.Errorf("link: %w", err)
		}
		return q.TouchDevice(ctx, sqlcdb.TouchDeviceParams{PlayerID: me.ID, DeviceHash: hash})
	})
	if err != nil {
		return nil, err
	}
	return d.GetReferral(ctx, playerID)
}

// payReferrals is the job that pays both sides, by letter, for every friend
// who has reached the reward level. A job rather than a step in the level-up:
// a level is reached in a dozen places (a collect, a raid, a letter, a quest),
// and a letter that failed there must not fail the collect. Each friend is paid
// in their own transaction, once.
func payReferrals(ctx context.Context, d Deps, _ time.Time) error {
	cfg := d.Config.Rewards.Referral
	ids, err := sqlcdb.New(d.Pool).ListDueReferrals(ctx, int32(cfg.RewardLevel))
	if err != nil {
		return fmt.Errorf("due referrals: %w", err)
	}
	var failed int
	for _, id := range ids {
		if err := db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
			q := sqlcdb.New(tx)
			invitee, err := q.GetPlayerByID(ctx, id)
			if err != nil {
				return err
			}
			return d.payReferral(ctx, q, invitee)
		}); err != nil {
			failed++
			if d.Log != nil {
				d.Log.Warn("referral reward", "invitee", id, "err", err)
			}
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d referral rewards failed", failed)
	}
	return nil
}

// payReferral pays both sides for one friend, once.
func (d Deps) payReferral(ctx context.Context, q *sqlcdb.Queries, invitee sqlcdb.AppPlayer) error {
	cfg := d.Config.Rewards.Referral
	if int(invitee.Level) < cfg.RewardLevel {
		return nil
	}
	now := d.Now()
	link, err := q.MarkReferralRewarded(ctx, sqlcdb.MarkReferralRewardedParams{InviteeID: invitee.ID, At: &now})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // no friend brought them, or already paid
	}
	if err != nil {
		return fmt.Errorf("mark referral: %w", err)
	}
	inviter, err := q.GetPlayerByID(ctx, link.InviterID)
	if err != nil {
		return nil // the inviter has gone; the friend is still paid below
	}
	if _, err := d.SendMail(ctx, q, inviter.ID, MailDraft{
		Kind: MailReferral, Sender: "The Crown", Title: "A friend has risen",
		Body: fmt.Sprintf("%s, whom you brought to the realm, has reached level %d. The Crown rewards you both.",
			invitee.DisplayName, cfg.RewardLevel),
		Attachments: gameconfig.RewardBundle{Diamonds: cfg.InviterDiamonds},
		IdemKey:     fmt.Sprintf("referral:%s:inviter", invitee.ID),
	}); err != nil {
		return err
	}
	if _, err := d.SendMail(ctx, q, invitee.ID, MailDraft{
		Kind: MailReferral, Sender: "The Crown", Title: "Welcome, risen lord",
		Body: fmt.Sprintf("You have reached level %d, and %s, who brought you, is rewarded too.",
			cfg.RewardLevel, inviter.DisplayName),
		Attachments: gameconfig.RewardBundle{Diamonds: cfg.InviteeDiamonds},
		IdemKey:     fmt.Sprintf("referral:%s:invitee", invitee.ID),
	}); err != nil {
		return err
	}
	return nil
}
