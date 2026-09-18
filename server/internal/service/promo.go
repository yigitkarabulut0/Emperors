package service

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/db"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/game/rewards"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// Promo codes: made in the panel (admin/promo.go), redeemed here, delivered by
// the Royal Mail. Once per lord and once per phone, and a lord who keeps
// guessing is made to wait: a code must be given, not found.

var (
	ErrPromoInvalid   = errors.New("that code is not one the Crown has issued, or its time has passed")
	ErrPromoUsed      = errors.New("that code has already been redeemed")
	ErrPromoTooMany   = errors.New("too many codes tried; wait a while and try again")
	ErrNoDevice       = errors.New("this phone did not say which phone it is")
	ErrReferralClosed = errors.New("a friend's code can no longer be entered on this account")
	ErrReferralCode   = errors.New("that is not a lord's code")
	ErrReferralSelf   = errors.New("that code is your own")
	ErrReferralLimit  = errors.New("that lord has brought all the friends they can for now")
)

// deviceHash is a keyed hash of a phone's own identifier: enough to say two
// accounts share a phone, useless to anyone who reads the table. Keyed with the
// server's secret, which never leaves it.
func (d Deps) deviceHash(device string) string {
	mac := hmac.New(sha256.New, d.ShopSecret)
	mac.Write([]byte("device:" + device))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

// validDevice is an identifier worth hashing: the phone's own, not a blank.
func validDevice(device string) bool {
	if n := len(device); n < 8 || n > 128 {
		return false
	}
	for _, r := range device {
		if r < 0x21 || r > 0x7e {
			return false
		}
	}
	return true
}

// SeeDevice records the phone a lord signed in on. Best effort: a sign-in
// never fails because of it, and an old build that sends nothing records
// nothing.
func (d Deps) SeeDevice(ctx context.Context, playerID uuid.UUID, device string) {
	if !validDevice(device) {
		return
	}
	if err := sqlcdb.New(d.Pool).TouchDevice(ctx, sqlcdb.TouchDeviceParams{
		PlayerID: playerID, DeviceHash: d.deviceHash(device),
	}); err != nil && d.Log != nil {
		d.Log.Warn("record device", "player", playerID, "err", err)
	}
}

// PromoResult is what a redemption says: the letter on its way.
type PromoResult struct {
	Title string         `json:"title"`
	Lines []rewards.Line `json:"lines"`
}

// NormalizePromo is a code as it is kept: upper case, no spaces or dashes.
func NormalizePromo(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(code) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// RedeemPromo redeems a code for a lord, on this phone, and sends its reward
// as a letter.
func (d Deps) RedeemPromo(ctx context.Context, playerID uuid.UUID, code, device string) (*PromoResult, error) {
	if !validDevice(device) {
		return nil, ErrNoDevice
	}
	code = NormalizePromo(code)
	cfg := d.Config.Rewards.Promo
	now := d.Now()
	q := sqlcdb.New(d.Pool)

	failures, err := q.CountPromoFailures(ctx, sqlcdb.CountPromoFailuresParams{PlayerID: playerID, Since: now.Add(-time.Hour)})
	if err != nil {
		return nil, fmt.Errorf("promo failures: %w", err)
	}
	if int(failures) >= cfg.FailuresPerHour {
		return nil, ErrPromoTooMany
	}
	fail := func(e error) (*PromoResult, error) {
		if err := q.RecordPromoFailure(ctx, playerID); err != nil && d.Log != nil {
			d.Log.Warn("record promo failure", "err", err)
		}
		return nil, e
	}
	if len(code) < 4 || len(code) > 20 {
		return fail(ErrPromoInvalid)
	}
	hash := d.deviceHash(device)

	var out PromoResult
	err = db.InTx(ctx, d.Pool, func(tx pgx.Tx) error {
		tq := sqlcdb.New(tx)
		p, err := tq.LockPlayer(ctx, playerID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("lock player: %w", err)
		}
		used, err := tq.PromoRedeemed(ctx, sqlcdb.PromoRedeemedParams{Promo: code, PlayerID: playerID, DeviceHash: hash})
		if err != nil {
			return fmt.Errorf("promo redeemed: %w", err)
		}
		if used.ByLord || used.ByDevice {
			return ErrPromoUsed
		}
		row, err := tq.UsePromoCode(ctx, sqlcdb.UsePromoCodeParams{Code: code, Now: now})
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrPromoInvalid
		}
		if err != nil {
			return fmt.Errorf("use promo: %w", err)
		}
		var reward gameconfig.RewardBundle
		if err := json.Unmarshal(row.Reward, &reward); err != nil {
			return fmt.Errorf("promo reward: %w", err)
		}
		if err := tq.InsertPromoRedemption(ctx, sqlcdb.InsertPromoRedemptionParams{
			Code: code, PlayerID: playerID, DeviceHash: hash,
		}); err != nil {
			return fmt.Errorf("record redemption: %w", err)
		}
		if err := tq.TouchDevice(ctx, sqlcdb.TouchDeviceParams{PlayerID: playerID, DeviceHash: hash}); err != nil {
			return fmt.Errorf("record device: %w", err)
		}
		out.Title = "A gift from the Crown"
		if _, err := d.SendMail(ctx, tq, p.ID, MailDraft{
			Kind: MailPromo, Sender: "The Crown", Title: out.Title,
			Body:        fmt.Sprintf("For the code %s. Long may you reign.", code),
			Attachments: reward, ExpiresAt: now.AddDate(0, 0, cfg.ExpiryDays),
			IdemKey: fmt.Sprintf("promo:%s:%s", code, p.ID),
		}); err != nil {
			return err
		}
		// What it will pay, resolved for this lord as the letter will be.
		eff, err := d.loadEffects(ctx, tq, p)
		if err != nil {
			return err
		}
		out.Lines = rewards.Lines(d.Config, reward, rewards.Resolve(d.Config, reward, int(p.Level), eff.Bonuses))
		return nil
	})
	if errors.Is(err, ErrPromoInvalid) || errors.Is(err, ErrPromoUsed) {
		return fail(err)
	}
	if err != nil {
		return nil, err
	}
	return &out, nil
}

func purgePromoFailures(ctx context.Context, d Deps, now time.Time) error {
	if _, err := sqlcdb.New(d.Pool).PurgePromoFailures(ctx, now.Add(-24*time.Hour)); err != nil {
		return fmt.Errorf("purge promo failures: %w", err)
	}
	return nil
}
