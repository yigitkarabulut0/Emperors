//go:build integration

package itest

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/admin"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

func designer(t *testing.T, w *world) (*admin.Service, *admin.Identity) {
	t.Helper()
	u, err := w.q.CreateAdminUser(w.ctx, sqlcdb.CreateAdminUserParams{
		Username: "it" + uuid.NewString()[:8], PasswordHash: "x", Role: "designer",
	})
	if err != nil {
		t.Fatal(err)
	}
	// The panel and the game on one clock, as they are in production.
	return &admin.Service{Pool: pool, Config: gameconfig.NewStore(w.d.Config, nil, nil),
			Now: func() int64 { return w.now.Unix() }},
		&admin.Identity{ID: u.ID, Username: u.Username, Role: "designer"}
}

func mailCount(w *world, id uuid.UUID, kind string) int {
	var n int
	_ = pool.QueryRow(w.ctx, `SELECT count(*) FROM app.mail WHERE player_id = $1 AND kind = $2`, id, kind).Scan(&n)
	return n
}

// A code gives only what play gives, once per lord and once per phone, and
// guessing is throttled.
func TestPromoCodes(t *testing.T) {
	w := newWorld(t)
	svc, who := designer(t, w)
	code := "SPRING" + uuid.NewString()[:4]

	for name, bad := range map[string]gameconfig.RewardBundle{
		"nothing":       {},
		"a cosmetic":    {Cosmetics: []string{"frame_laurel"}},
		"too many gems": {Diamonds: w.d.Config.Rewards.Promo.MaxDiamonds + 1},
	} {
		if _, err := svc.CreatePromo(w.ctx, who, admin.PromoCreate{Code: code, Reward: bad}); !errors.Is(err, admin.ErrOutOfRange) {
			t.Fatalf("a code giving %s was made: %v", name, err)
		}
	}
	if _, err := svc.CreatePromo(w.ctx, &admin.Identity{Username: "mod", Role: "moderator"},
		admin.PromoCreate{Code: code, Reward: gameconfig.RewardBundle{Diamonds: 5}}); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator made a code: %v", err)
	}
	made, err := svc.CreatePromo(w.ctx, who, admin.PromoCreate{Code: code, MaxUses: 2, ExpiresDays: 7,
		Reward: gameconfig.RewardBundle{Diamonds: 20, Tokens: map[string]int64{"energy_potion": 1}}})
	if err != nil || made.State != "live" {
		t.Fatalf("a code: %+v, %v", made, err)
	}

	a, b, c := w.player(5, 0), w.player(5, 0), w.player(5, 0)
	phoneA, phoneB, phoneC := "PHONE-A-"+uuid.NewString(), "PHONE-B-"+uuid.NewString(), "PHONE-C-"+uuid.NewString()
	res, err := w.d.RedeemPromo(w.ctx, a.ID, " "+code[:3]+"-"+code[3:]+" ", phoneA) // spaced and dashed, as typed
	if err != nil || len(res.Lines) != 2 {
		t.Fatalf("redeeming: %+v, %v", res, err)
	}
	if mailCount(w, a.ID, service.MailPromo) != 1 {
		t.Fatal("the code's letter did not arrive")
	}
	if _, err := w.d.RedeemPromo(w.ctx, a.ID, code, phoneA); !errors.Is(err, service.ErrPromoUsed) {
		t.Fatalf("a lord redeemed a code twice: %v", err)
	}
	if _, err := w.d.RedeemPromo(w.ctx, b.ID, code, phoneA); !errors.Is(err, service.ErrPromoUsed) {
		t.Fatalf("a second lord on the same phone redeemed it: %v", err)
	}
	if _, err := w.d.RedeemPromo(w.ctx, b.ID, code, phoneB); err != nil {
		t.Fatalf("a second lord on their own phone: %v", err)
	}
	if _, err := w.d.RedeemPromo(w.ctx, c.ID, code, phoneC); !errors.Is(err, service.ErrPromoInvalid) {
		t.Fatalf("a code past its two uses: %v", err)
	}
	if _, err := w.d.RedeemPromo(w.ctx, c.ID, code, ""); !errors.Is(err, service.ErrNoDevice) {
		t.Fatalf("a redemption with no phone: %v", err)
	}

	// Guessing: the eighth wrong code in an hour is the last.
	guesser := w.player(5, 0)
	phone := "PHONE-G-" + uuid.NewString()
	for i := 0; i < w.d.Config.Rewards.Promo.FailuresPerHour; i++ {
		if _, err := w.d.RedeemPromo(w.ctx, guesser.ID, "NOPE"+uuid.NewString()[:6], phone); !errors.Is(err, service.ErrPromoInvalid) {
			t.Fatalf("guess %d: %v", i, err)
		}
	}
	if _, err := w.d.RedeemPromo(w.ctx, guesser.ID, code, phone); !errors.Is(err, service.ErrPromoTooMany) {
		t.Fatalf("after the allowance of wrong codes: %v", err)
	}

	// Disabled, it stops.
	other := "AUTUMN" + uuid.NewString()[:4]
	if _, err := svc.CreatePromo(w.ctx, who, admin.PromoCreate{Code: other, Reward: gameconfig.RewardBundle{Diamonds: 5}}); err != nil {
		t.Fatal(err)
	}
	if row, err := svc.DisablePromo(w.ctx, who, other, "a typo"); err != nil || row.State != "disabled" {
		t.Fatalf("disabling: %+v, %v", row, err)
	}
	if _, err := w.d.RedeemPromo(w.ctx, c.ID, other, phoneC); !errors.Is(err, service.ErrPromoInvalid) {
		t.Fatalf("a disabled code: %v", err)
	}
	reds, err := svc.PromoRedemptions(w.ctx, code)
	if err != nil || len(reds) != 2 {
		t.Fatalf("redemptions: %d, %v", len(reds), err)
	}
}

// A friend's code: within the first week, never one's own or from the
// inviter's phone, capped; both are paid by letter when the friend reaches the
// level, once.
func TestBringingAFriend(t *testing.T) {
	w := newWorld(t)
	cfg := w.d.Config.Rewards.Referral
	inviter := w.player(20, 0)
	w.exec(`UPDATE app.players SET created_at = now() - interval '10 days' WHERE id = $1`, inviter.ID)
	inviterPhone := "PHONE-I-" + uuid.NewString()
	w.d.SeeDevice(w.ctx, inviter.ID, inviterPhone)
	v, err := w.d.GetReferral(w.ctx, inviter.ID)
	if err != nil || len(v.Code) != 6 {
		t.Fatalf("the inviter's code: %+v, %v", v, err)
	}
	if again, _ := w.d.GetReferral(w.ctx, inviter.ID); again.Code != v.Code {
		t.Fatal("a lord's code changed between two looks")
	}
	if v.CanClaim {
		t.Fatal("a ten-day-old level 20 lord may still enter a friend's code")
	}

	friend := w.player(3, 0)
	friendPhone := "PHONE-F-" + uuid.NewString()
	if fv, _ := w.d.GetReferral(w.ctx, friend.ID); !fv.CanClaim || fv.ClaimInS <= 0 {
		t.Fatalf("a new lord cannot enter a code: %+v", fv)
	}
	if _, err := w.d.ClaimReferral(w.ctx, friend.ID, "ZZZZZZ", friendPhone); !errors.Is(err, service.ErrReferralCode) {
		t.Fatalf("an unknown code: %v", err)
	}
	own, _ := w.d.GetReferral(w.ctx, friend.ID)
	if _, err := w.d.ClaimReferral(w.ctx, friend.ID, own.Code, friendPhone); !errors.Is(err, service.ErrReferralSelf) {
		t.Fatalf("a lord's own code: %v", err)
	}
	if _, err := w.d.ClaimReferral(w.ctx, friend.ID, v.Code, inviterPhone); !errors.Is(err, service.ErrReferralSelf) {
		t.Fatalf("a friend on the inviter's own phone: %v", err)
	}
	fv, err := w.d.ClaimReferral(w.ctx, friend.ID, v.Code, friendPhone)
	if err != nil || fv.CanClaim || fv.ClaimedBy != inviter.DisplayName {
		t.Fatalf("the friend's claim: %+v, %v", fv, err)
	}
	if _, err := w.d.ClaimReferral(w.ctx, friend.ID, v.Code, friendPhone); !errors.Is(err, service.ErrReferralClosed) {
		t.Fatalf("a second claim: %v", err)
	}

	// A fresh inviter cannot be named: their account is too young.
	young := w.player(20, 0)
	yv, _ := w.d.GetReferral(w.ctx, young.ID)
	late := w.player(3, 0)
	if _, err := w.d.ClaimReferral(w.ctx, late.ID, yv.Code, "PHONE-L-"+uuid.NewString()); !errors.Is(err, service.ErrReferralCode) {
		t.Fatalf("an inviter younger than %dh: %v", cfg.InviterMinHours, err)
	}

	// Below the level: nothing is paid.
	run := func() {
		for _, j := range service.ScheduledJobs() {
			if j.Name == "referral_rewards" {
				if err := j.Run(w.ctx, w.d, time.Now().UTC()); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	run()
	if mailCount(w, inviter.ID, service.MailReferral) != 0 {
		t.Fatal("the inviter was paid before the friend reached the level")
	}
	// At the level: both, once.
	w.exec(`UPDATE app.players SET level = $2 WHERE id = $1`, friend.ID, cfg.RewardLevel)
	run()
	run()
	if mailCount(w, inviter.ID, service.MailReferral) != 1 || mailCount(w, friend.ID, service.MailReferral) != 1 {
		t.Fatalf("letters: inviter %d, friend %d; want one each",
			mailCount(w, inviter.ID, service.MailReferral), mailCount(w, friend.ID, service.MailReferral))
	}
	after, _ := w.d.GetReferral(w.ctx, inviter.ID)
	if after.Rewarded != 1 || len(after.Friends) != 1 || !after.Friends[0].Rewarded {
		t.Fatalf("the inviter's view after: %+v", after)
	}
	if after.Friends[0].Avatar == "" || after.Friends[0].Name != friend.DisplayName {
		t.Fatalf("the friend is listed without their face: %+v", after.Friends[0])
	}
}
