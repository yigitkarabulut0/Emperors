//go:build integration

package itest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// HERALD'S TIDINGS, end to end: the rewarded advert.
//
// The rule the whole thing rests on is that THE CLIENT NEVER SAYS "I WATCHED
// IT". Every check below is really one check: nothing but a signature of
// Google's turns a ticket into diamonds -- not a tap, not a second callback,
// not another lord's ticket, and not a forged one.

// heraldKey gives the world a herald with one trusted key, and returns the key
// to sign callbacks with.
func heraldKey(w *world) *ecdsa.PrivateKey {
	w.t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		w.t.Fatal(err)
	}
	h := &service.Herald{UnitID: "ca-app-pub-itest/1111111111"}
	h.Trust(map[int64]*ecdsa.PublicKey{7: &key.PublicKey})
	w.d.Herald = h
	return key
}

// callback is what Google sends: the query signed as it will arrive, byte for
// byte. Built by hand rather than through url.Values, because that is what the
// signature is over.
func callback(w *world, key *ecdsa.PrivateKey, keyID int64, ticket, lord, txn string, at time.Time) string {
	w.t.Helper()
	fields := [][2]string{
		{"ad_network", "5450213213286189855"},
		{"ad_unit", "ca-app-pub-itest/1111111111"},
		{"custom_data", ticket},
		{"reward_amount", "1"},
		{"reward_item", "diamonds"},
		{"timestamp", fmt.Sprint(at.UnixMilli())},
		{"transaction_id", txn},
		{"user_id", lord},
	}
	parts := make([]string, 0, len(fields))
	for _, f := range fields {
		parts = append(parts, f[0]+"="+url.QueryEscape(f[1]))
	}
	body := strings.Join(parts, "&")
	sum := sha256.Sum256([]byte(body))
	sig, err := ecdsa.SignASN1(rand.Reader, key, sum[:])
	if err != nil {
		w.t.Fatal(err)
	}
	return fmt.Sprintf("%s&signature=%s&key_id=%d", body,
		base64.RawURLEncoding.EncodeToString(sig), keyID)
}

// heraldLord is a lord old enough for the herald.
func heraldLord(w *world) uuid.UUID {
	w.t.Helper()
	p := w.player(int32(maxInt(w.d.Config.Commerce.Ads.MinLevel, 5)), 0)
	return p.ID
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// A realm with no adverts shows no herald and hands out no tickets.
func TestAHeraldWithNoAdvertsIsShut(t *testing.T) {
	w := newWorld(t)
	p := heraldLord(w)
	// w.d.Herald is nil: this is the state the server ships in.
	store, err := w.d.GetCourtStore(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if store.Herald.Enabled {
		t.Error("the store offered a herald on a realm with no adverts")
	}
	if _, err := w.d.StartAdWatch(w.ctx, p); !errors.Is(err, service.ErrHeraldShut) {
		t.Fatalf("a ticket was handed out with no advert to play: %v", err)
	}
}

// With an advert to play, the store says what one is worth -- in the server's
// own words -- and how many are left.
func TestTheHeraldSaysWhatOneIsWorth(t *testing.T) {
	w := newWorld(t)
	heraldKey(w)
	p := heraldLord(w)
	cfg := w.d.Config.Commerce.Ads

	store, err := w.d.GetCourtStore(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	h := store.Herald
	if !h.Enabled || !h.Unlocked {
		t.Fatal("the herald is shut with an advert to play")
	}
	if h.Left != cfg.PerDay || h.PerDay != cfg.PerDay {
		t.Errorf("a lord who has watched none has %d of %d left", h.Left, h.PerDay)
	}
	if h.Diamonds != cfg.Grant.Diamonds || len(h.Lines) == 0 {
		t.Errorf("the herald offers %d diamonds and says %v", h.Diamonds, h.Lines)
	}
	if h.Unit == "" {
		t.Error("the herald names no advert for the client to play")
	}
}

// A tap is a ticket, and a second tap is the SAME ticket: a lord who lost the
// answer must not lose the advert they are already watching.
func TestATapIsATicketAndASecondTapIsTheSameOne(t *testing.T) {
	w := newWorld(t)
	heraldKey(w)
	p := heraldLord(w)

	first, err := w.d.StartAdWatch(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if first.Ticket == "" || first.UserID != p.String() || first.ExpiresIn <= 0 {
		t.Fatalf("the ticket reads %+v", first)
	}
	again, err := w.d.StartAdWatch(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if again.Ticket != first.Ticket {
		t.Errorf("a second tap minted a second ticket: %s then %s", first.Ticket, again.Ticket)
	}
	if n := w.count(`SELECT count(*) FROM app.ad_watches WHERE player_id = $1`, p); n != 1 {
		t.Errorf("two taps wrote %d rows", n)
	}
}

// The whole feature in one test: a signed callback pays, and nothing else does.
func TestOnlyGooglesSignatureTurnsATicketIntoDiamonds(t *testing.T) {
	w := newWorld(t)
	key := heraldKey(w)
	p := heraldLord(w)
	before := w.reload(p).Diamonds

	ticket, err := w.d.StartAdWatch(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}

	// A forgery, signed with a key that is not the herald's.
	other, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	forged := callback(w, other, 7, ticket.Ticket, p.String(), "forged-1", w.now)
	if err := w.d.CreditAdWatch(w.ctx, forged); err == nil {
		t.Error("a callback signed with somebody else's key was paid")
	}
	if got := w.reload(p).Diamonds; got != before {
		t.Fatalf("a forgery moved the purse: %d -> %d", before, got)
	}

	// Another lord's ticket, correctly signed: the callback names a lord the
	// ticket does not.
	stranger := heraldLord(w)
	wrong := callback(w, key, 7, ticket.Ticket, stranger.String(), "wrong-lord-1", w.now)
	if err := w.d.CreditAdWatch(w.ctx, wrong); err == nil {
		t.Error("a callback pointed one lord's watch at another lord's purse")
	}
	if got := w.reload(stranger).Diamonds; got != 0 {
		t.Fatalf("the stranger was paid %d", got)
	}

	// The genuine article.
	good := callback(w, key, 7, ticket.Ticket, p.String(), "txn-1", w.now)
	if err := w.d.CreditAdWatch(w.ctx, good); err != nil {
		t.Fatalf("a callback this test signed with the herald's own key was refused: %v", err)
	}
	want := before + w.d.Config.Commerce.Ads.Grant.Diamonds
	if got := w.reload(p).Diamonds; got != want {
		t.Fatalf("the advert paid %d, want %d", got-before, want-before)
	}

	// And Google's retries pay nothing more -- the same transaction, and a
	// second transaction against a watch already paid.
	if err := w.d.CreditAdWatch(w.ctx, good); err != nil {
		t.Fatalf("a retry of a paid callback errored: %v", err)
	}
	twice := callback(w, key, 7, ticket.Ticket, p.String(), "txn-2", w.now)
	if err := w.d.CreditAdWatch(w.ctx, twice); err != nil {
		t.Fatalf("a second callback for a paid watch errored: %v", err)
	}
	if got := w.reload(p).Diamonds; got != want {
		t.Fatalf("a retried callback paid again: %d, want %d", got, want)
	}
	if n := w.count(`SELECT count(*) FROM app.ad_watches WHERE player_id = $1 AND paid_at IS NOT NULL`, p); n != 1 {
		t.Errorf("%d watches were paid", n)
	}
}

// A ticket nobody came back for in time is dead, and the sweep takes it.
func TestAnExpiredTicketPaysNothingAndIsSweptAway(t *testing.T) {
	w := newWorld(t)
	key := heraldKey(w)
	p := heraldLord(w)
	ticket, err := w.d.StartAdWatch(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	w.exec(`UPDATE app.ad_watches SET expires_at = $2 WHERE id = $1`,
		uuid.MustParse(ticket.Ticket), w.now.Add(-time.Minute))

	late := callback(w, key, 7, ticket.Ticket, p.String(), "late-1", w.now)
	if err := w.d.CreditAdWatch(w.ctx, late); err == nil {
		t.Error("an expired ticket was paid")
	}
	if got := w.reload(p).Diamonds; got != 0 {
		t.Fatalf("an expired ticket paid %d", got)
	}
	w.runJob("ad_watch_purge")
	if n := w.count(`SELECT count(*) FROM app.ad_watches WHERE player_id = $1`, p); n != 0 {
		t.Errorf("the sweep left %d dead tickets", n)
	}
}

// Five a day, and the day's allowance is counted from watches that were PAID --
// a tap that went nowhere costs the lord nothing.
func TestTheDaysAllowanceIsCountedFromWhatWasPaid(t *testing.T) {
	w := newWorld(t)
	key := heraldKey(w)
	p := heraldLord(w)
	cfg := w.d.Config.Commerce.Ads

	for i := 0; i < cfg.PerDay; i++ {
		// The cooldown is stepped over by moving the clock, not by reaching
		// past the rule.
		w.now = w.now.Add(time.Duration(cfg.CooldownMinutes+1) * time.Minute)
		ticket, err := w.d.StartAdWatch(w.ctx, p)
		if err != nil {
			t.Fatalf("watch %d: %v", i+1, err)
		}
		raw := callback(w, key, 7, ticket.Ticket, p.String(), fmt.Sprintf("day-%d", i), w.now)
		if err := w.d.CreditAdWatch(w.ctx, raw); err != nil {
			t.Fatalf("watch %d: %v", i+1, err)
		}
	}
	want := cfg.Grant.Diamonds * int64(cfg.PerDay)
	if got := w.reload(p).Diamonds; got != want {
		t.Fatalf("%d adverts paid %d diamonds, want %d", cfg.PerDay, got, want)
	}

	w.now = w.now.Add(time.Hour)
	if _, err := w.d.StartAdWatch(w.ctx, p); !errors.Is(err, service.ErrHeraldSpent) {
		t.Fatalf("a %dth advert was offered: %v", cfg.PerDay+1, err)
	}
	store, err := w.d.GetCourtStore(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if store.Herald.Left != 0 {
		t.Errorf("the store says %d are left after the day's allowance", store.Herald.Left)
	}

	// And tomorrow the herald is back.
	w.now = w.now.Add(24 * time.Hour)
	if _, err := w.d.StartAdWatch(w.ctx, p); err != nil {
		t.Fatalf("the next day refused a watch: %v", err)
	}
}

// Between adverts the herald catches his breath.
func TestTheHeraldRestsBetweenAdverts(t *testing.T) {
	w := newWorld(t)
	key := heraldKey(w)
	p := heraldLord(w)
	cfg := w.d.Config.Commerce.Ads
	if cfg.CooldownMinutes <= 0 {
		t.Skip("this balance has no cooldown")
	}
	ticket, err := w.d.StartAdWatch(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.d.CreditAdWatch(w.ctx,
		callback(w, key, 7, ticket.Ticket, p.String(), "rest-1", w.now)); err != nil {
		t.Fatal(err)
	}
	if _, err := w.d.StartAdWatch(w.ctx, p); !errors.Is(err, service.ErrHeraldSoon) {
		t.Fatalf("a second advert was offered at once: %v", err)
	}
	store, err := w.d.GetCourtStore(w.ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if store.Herald.NextIn <= 0 {
		t.Error("the store does not say when the next may be watched")
	}
	w.now = w.now.Add(time.Duration(cfg.CooldownMinutes+1) * time.Minute)
	if _, err := w.d.StartAdWatch(w.ctx, p); err != nil {
		t.Fatalf("the herald never caught his breath: %v", err)
	}
}

// A lord too young for the herald sees the plate with its level on it, and is
// told THAT -- not that the realm has no adverts, which is a different state
// with a different answer.
func TestTheHeraldWaitsForALordToGrow(t *testing.T) {
	w := newWorld(t)
	heraldKey(w)
	cfg := w.d.Config.Commerce.Ads
	if cfg.MinLevel <= 1 {
		t.Skip("this balance opens the herald at level one")
	}
	young := w.player(1, 0)
	store, err := w.d.GetCourtStore(w.ctx, young.ID)
	if err != nil {
		t.Fatal(err)
	}
	h := store.Herald
	if !h.Enabled {
		t.Error("a realm with an advert to play hid the herald from a young lord")
	}
	if h.Unlocked {
		t.Error("a lord of level one was offered an advert")
	}
	if h.UnlockLevel != cfg.MinLevel {
		t.Errorf("the plate says level %d, the balance says %d", h.UnlockLevel, cfg.MinLevel)
	}
	if h.Left != 0 {
		t.Errorf("a locked plate counted an allowance: %d left", h.Left)
	}
	if len(h.Lines) == 0 || h.Diamonds != cfg.Grant.Diamonds {
		t.Errorf("a locked plate does not say what one is worth: %d, %v", h.Diamonds, h.Lines)
	}
	if _, err := w.d.StartAdWatch(w.ctx, young.ID); !errors.Is(err, service.ErrHeraldEarly) {
		t.Fatalf("a lord of level one was handed a ticket: %v", err)
	}
}
