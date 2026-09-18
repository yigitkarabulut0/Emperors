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

func (w *world) send(p sqlcdb.AppPlayer, key string, b gameconfig.RewardBundle) {
	w.t.Helper()
	sent, err := w.d.SendMail(w.ctx, w.q, p.ID, service.MailDraft{
		Kind: service.MailGift, Title: "A gift from the Crown", Body: "For your service.",
		Attachments: b, IdemKey: key,
	})
	if err != nil || !sent {
		w.t.Fatalf("send %s: sent=%v err=%v", key, sent, err)
	}
}

func (w *world) letterID(p sqlcdb.AppPlayer) int64 {
	w.t.Helper()
	box, err := w.d.GetMail(w.ctx, p.ID)
	if err != nil || len(box.Mail) == 0 {
		w.t.Fatalf("inbox: %v (%d letters)", err, len(box.Mail))
	}
	return box.Mail[0].ID
}

// A letter pays everything it carries, once, and every currency it moves is in
// its ledger.
func TestALetterPaysOnce(t *testing.T) {
	w := newWorld(t)
	p := w.player(20, 0)
	w.send(p, "gift-1", gameconfig.RewardBundle{
		Diamonds: 50, Gold: 1234, Favour: 7,
		Tokens: map[string]int64{"energy_potion": 2},
		Items:  []gameconfig.ItemGrant{{Slot: "horse", Tier: "rare", Count: 1}},
		Boosts: []gameconfig.BoostGrant{{Bucket: gameconfig.BucketXP, BP: 5000, Hours: 24}},
	})
	id := w.letterID(p)

	res, err := w.d.ClaimMail(w.ctx, p.ID, id)
	if err != nil {
		t.Fatal(err)
	}
	after := w.reload(p.ID)
	if after.Diamonds != 50 || after.Gold != 1234 || after.KingdomFavour != 7 {
		t.Fatalf("after the letter: %d diamonds, %d gold, %d favour", after.Diamonds, after.Gold, after.KingdomFavour)
	}
	if len(res.Granted.Items) != 1 || res.Granted.Items[0].Slot != "horse" || res.Granted.Items[0].Ilvl != 20 {
		t.Fatalf("items granted: %+v", res.Granted.Items)
	}
	var potions int64
	if err := pool.QueryRow(w.ctx, `SELECT qty FROM app.player_tokens WHERE player_id=$1 AND token='energy_potion'`,
		p.ID).Scan(&potions); err != nil || potions != 2 {
		t.Fatalf("potions held: %d (%v)", potions, err)
	}
	if after.BoostUntil == nil || !after.BoostUntil.After(w.now.Add(23*time.Hour)) {
		t.Fatalf("the timed bonus was not recorded: boost_until %v", after.BoostUntil)
	}
	var from string
	if err := pool.QueryRow(w.ctx, `SELECT acquired_from FROM app.player_items WHERE player_id=$1`,
		p.ID).Scan(&from); err != nil || from != "mail" {
		t.Fatalf("the horse came from %q (%v), want mail", from, err)
	}
	var goldReason string
	if err := pool.QueryRow(w.ctx, `SELECT reason FROM app.gold_ledger WHERE player_id=$1`, p.ID).Scan(&goldReason); err != nil || goldReason != "mail" {
		t.Fatalf("gold ledger reason %q (%v)", goldReason, err)
	}

	if _, err := w.d.ClaimMail(w.ctx, p.ID, id); !errors.Is(err, service.ErrMailClaimed) {
		t.Fatalf("a second claim: %v, want already opened", err)
	}
	if w.reload(p.ID).Diamonds != 50 {
		t.Fatal("a second claim paid again")
	}
}

// The same key delivers one letter however many times it is sent.
func TestASendIsIdempotent(t *testing.T) {
	w := newWorld(t)
	p := w.player(5, 0)
	w.send(p, "season-1", gameconfig.RewardBundle{Diamonds: 10})
	sent, err := w.d.SendMail(w.ctx, w.q, p.ID, service.MailDraft{
		Kind: service.MailGift, Title: "Again", Attachments: gameconfig.RewardBundle{Diamonds: 10}, IdemKey: "season-1",
	})
	if err != nil || sent {
		t.Fatalf("the repeat send: sent=%v err=%v", sent, err)
	}
	box, _ := w.d.GetMail(w.ctx, p.ID)
	if len(box.Mail) != 1 {
		t.Fatalf("%d letters after sending one twice", len(box.Mail))
	}
}

// CLAIM ALL opens what fits and leaves a letter whose gear has nowhere to go.
func TestClaimAllLeavesWhatWillNotFit(t *testing.T) {
	w := newWorld(t)
	p := w.player(10, 0)
	// Fill the armory to one below its cap.
	w.exec(`INSERT INTO app.player_items (player_id, def_id, slot, tier, ilvl, quality_pct, masterwork,
	         attack, defense, speed, acquired_from, rolled_config_version)
	        SELECT $1, 'w_c_1', 'weapon', 'common', 1, 100, false, 1, 0, 0, 'admin', 1
	        FROM generate_series(1, $2::int)`, p.ID, w.d.Config.Items.InventoryCap-1)
	w.send(p, "big", gameconfig.RewardBundle{Items: []gameconfig.ItemGrant{{Tier: "common", Count: 2}}})
	w.send(p, "small", gameconfig.RewardBundle{Diamonds: 5})

	res, err := w.d.ClaimAllMail(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Claimed) != 1 || len(res.Skipped) != 1 || res.Skipped[0].Reason != "inventory_full" {
		t.Fatalf("claimed %v, skipped %+v", res.Claimed, res.Skipped)
	}
	if w.reload(p.ID).Diamonds != 5 {
		t.Fatal("the letter that fit was not paid")
	}
	box, _ := w.d.GetMail(w.ctx, p.ID)
	open := 0
	for _, l := range box.Mail {
		if l.Claimable {
			open++
		}
	}
	if open != 1 {
		t.Fatalf("%d letters still claimable, want the one that did not fit", open)
	}
}

// A letter to everyone reaches a lord the next time they look, once; a revoked
// one is taken back from anyone who has not opened it.
func TestALetterToEveryone(t *testing.T) {
	w := newWorld(t)
	early := w.player(8, 0)

	boss, err := w.q.CreateAdminUser(w.ctx, sqlcdb.CreateAdminUserParams{
		Username: "it" + uuid.NewString()[:8], PasswordHash: "x", Role: "owner",
	})
	if err != nil {
		t.Fatal(err)
	}
	store := gameconfig.NewStore(w.d.Config, nil, nil)
	svc := &admin.Service{Pool: pool, Config: store}
	who := &admin.Identity{ID: boss.ID, Username: boss.Username, Role: "owner"}

	sent, err := svc.SendMail(w.ctx, who, admin.MailSend{
		Target: "all", Title: "The realm thanks you", Attachments: gameconfig.RewardBundle{Diamonds: 25},
	})
	if err != nil {
		t.Fatal(err)
	}
	late := w.player(8, 0) // arrived after the letter; include_new was false

	b, err := w.d.GetBadges(w.ctx, early.ID)
	if err != nil || b.Mail < 1 {
		t.Fatalf("the heartbeat did not flag the letter: %+v %v", b, err)
	}
	if _, err := w.d.GetBadges(w.ctx, early.ID); err != nil {
		t.Fatal(err)
	}
	box, _ := w.d.GetMail(w.ctx, early.ID)
	copies := 0
	for _, l := range box.Mail {
		if l.Title == "The realm thanks you" {
			copies++
		}
	}
	if copies != 1 {
		t.Fatalf("the early lord holds %d copies, want exactly 1", copies)
	}
	if lateBox, _ := w.d.GetMail(w.ctx, late.ID); len(lateBox.Mail) != 0 {
		t.Fatalf("a lord who arrived after the letter got it (include_new was off): %d", len(lateBox.Mail))
	}

	pulled, err := svc.RevokeBroadcast(w.ctx, who, sent.BroadcastID, "itest")
	if err != nil || pulled != 1 {
		t.Fatalf("revoke pulled %d (%v), want the one unopened copy", pulled, err)
	}
	if after, _ := w.d.GetMail(w.ctx, early.ID); len(after.Mail) != 0 {
		t.Fatalf("a revoked letter is still in the inbox: %d", len(after.Mail))
	}

	// The history says what became of it: one copy written, none claimed, one
	// taken back.
	list, err := svc.Broadcasts(w.ctx, 20)
	if err != nil {
		t.Fatal(err)
	}
	var got *admin.Broadcast
	for i := range list {
		if list[i].ID == sent.BroadcastID {
			got = &list[i]
		}
	}
	if got == nil || !got.Revoked || got.Delivered != 1 || got.Claimed != 0 || got.Withdrawn != 1 || got.IncludeNew {
		t.Fatalf("the history reads %+v; want revoked, 1 delivered, 0 claimed, 1 withdrawn, not for new lords", got)
	}

	// A letter to one lord names them.
	one, err := svc.SendMail(w.ctx, who, admin.MailSend{
		Target: "player", PlayerID: early.ID.String(), Title: "For you alone",
	})
	if err != nil {
		t.Fatal(err)
	}
	list, _ = svc.Broadcasts(w.ctx, 20)
	for _, b := range list {
		if b.ID == one.BroadcastID && b.Recipient != early.Username {
			t.Fatalf("a letter to one lord names %q, want %q", b.Recipient, early.Username)
		}
	}
}

// Only the owner may send gifts to everyone; words alone are anyone's.
func TestMailRolesEscalateWithWhatItCarries(t *testing.T) {
	w := newWorld(t)
	p := w.player(5, 0)
	store := gameconfig.NewStore(w.d.Config, nil, nil)
	svc := &admin.Service{Pool: pool, Config: store}
	mod := &admin.Identity{Username: "mod", Role: "moderator"}

	if _, err := svc.SendMail(w.ctx, mod, admin.MailSend{
		Target: "player", PlayerID: p.ID.String(), Title: "Hello",
	}); err != nil {
		t.Fatalf("a moderator's plain letter: %v", err)
	}
	if _, err := svc.SendMail(w.ctx, mod, admin.MailSend{
		Target: "player", PlayerID: p.ID.String(), Title: "Gold",
		Attachments: gameconfig.RewardBundle{Gold: 1000},
	}); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a moderator sending gold: %v, want forbidden", err)
	}
	designer := &admin.Identity{Username: "des", Role: "designer"}
	if _, err := svc.SendMail(w.ctx, designer, admin.MailSend{
		Target: "all", Title: "Diamonds for all", Attachments: gameconfig.RewardBundle{Diamonds: 5},
	}); !errors.Is(err, admin.ErrForbidden) {
		t.Fatalf("a designer's gift to everyone: %v, want forbidden", err)
	}
	if _, err := svc.SendMail(w.ctx, designer, admin.MailSend{
		Target: "player", PlayerID: p.ID.String(), Title: "Bad",
		Attachments: gameconfig.RewardBundle{Tokens: map[string]int64{"dragon_egg": 1}},
	}); !errors.Is(err, admin.ErrOutOfRange) {
		t.Fatalf("an unknown token: %v, want refused", err)
	}
}

// A potion pays for a refill, and still counts as one of the day's three.
func TestAPotionIsOneOfTheDaysRefills(t *testing.T) {
	w := newWorld(t)
	p := w.player(12, 0)
	w.send(p, "potions", gameconfig.RewardBundle{Tokens: map[string]int64{"energy_potion": 5}})
	if _, err := w.d.ClaimMail(w.ctx, p.ID, w.letterID(p)); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		w.exec(`UPDATE app.players SET energy_milli = 0, energy_updated_at = $2 WHERE id = $1`, p.ID, w.now)
		p = w.reload(p.ID)
		if _, err := w.d.BuyStoreGood(w.ctx, p.ID, "energy_refill", service.PayToken, p.ActionSeq+1); err != nil {
			t.Fatalf("potion refill %d: %v", i+1, err)
		}
	}
	w.exec(`UPDATE app.players SET energy_milli = 0, energy_updated_at = $2 WHERE id = $1`, p.ID, w.now)
	p = w.reload(p.ID)
	if _, err := w.d.BuyStoreGood(w.ctx, p.ID, "energy_refill", service.PayToken, p.ActionSeq+1); !errors.Is(err, service.ErrRefillsExhausted) {
		t.Fatalf("a fourth refill by potion: %v, want the day's limit", err)
	}
	if p.Diamonds != 0 {
		t.Fatalf("potion refills cost %d diamonds", p.Diamonds)
	}
	store, err := w.d.GetStore(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if store.Goods[0].Tokens != 2 || store.Goods[0].TokenName != "Energy Potion" {
		t.Fatalf("the store shows %d %q, want 2 Energy Potion left", store.Goods[0].Tokens, store.Goods[0].TokenName)
	}
}

// A letter whose wages would level the player refills their pool to the new
// level's maximum, as every level-up does.
func TestALevelFromALetterRefillsThePool(t *testing.T) {
	w := newWorld(t)
	p := w.player(1, 0)
	w.exec(`UPDATE app.players SET energy_milli = 0, energy_updated_at = $2 WHERE id = $1`, p.ID, w.now)
	w.send(p, "xp", gameconfig.RewardBundle{XP: 500})
	if _, err := w.d.ClaimMail(w.ctx, p.ID, w.letterID(p)); err != nil {
		t.Fatal(err)
	}
	after := w.reload(p.ID)
	if after.Level <= 1 {
		t.Fatalf("500 experience left the lord at level %d", after.Level)
	}
	st, err := w.d.GetState(w.ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Energy.Current != st.Energy.Max {
		t.Fatalf("after levelling from a letter the pool is %d of %d", st.Energy.Current, st.Energy.Max)
	}
}

// A letter with something still in it cannot be thrown away; once claimed, or
// when it never carried anything, it can.
func TestALetterIsKeptUntilItIsEmpty(t *testing.T) {
	w := newWorld(t)
	p := w.player(5, 0)
	w.send(p, "keep-1", gameconfig.RewardBundle{Diamonds: 5})
	id := w.letterID(p)
	if err := w.d.DeleteMail(w.ctx, p.ID, id); !errors.Is(err, service.ErrMailKeep) {
		t.Fatalf("throwing away an unclaimed gift: %v, want it kept", err)
	}
	if _, err := w.d.ClaimMail(w.ctx, p.ID, id); err != nil {
		t.Fatal(err)
	}
	if err := w.d.DeleteMail(w.ctx, p.ID, id); err != nil {
		t.Fatalf("throwing away a claimed letter: %v", err)
	}

	if _, err := w.d.SendMail(w.ctx, w.q, p.ID, service.MailDraft{
		Kind: service.MailSystem, Title: "News from the Crown", Body: "The roads are open.",
	}); err != nil {
		t.Fatal(err)
	}
	box, err := w.d.GetMail(w.ctx, p.ID)
	if err != nil || len(box.Mail) != 1 {
		t.Fatalf("the inbox after one deletion and one letter: %d letters (%v)", len(box.Mail), err)
	}
	if box.Mail[0].Claimable {
		t.Fatal("a letter with nothing in it reads as claimable")
	}
	if err := w.d.DeleteMail(w.ctx, p.ID, box.Mail[0].ID); err != nil {
		t.Fatalf("throwing away a letter that never carried anything: %v", err)
	}
	if box, _ = w.d.GetMail(w.ctx, p.ID); len(box.Mail) != 0 {
		t.Fatalf("%d letters left after throwing both away", len(box.Mail))
	}
}
