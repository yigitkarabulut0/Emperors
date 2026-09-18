package ads

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"
)

// A callback signed with this test's own key: no account, no network, no
// advert. The signature is over the query as it ARRIVES, so the test builds the
// string by hand rather than through url.Values, which is exactly what the
// handler must do too.
func signed(t *testing.T, key *ecdsa.PrivateKey, keyID int64, fields [][2]string) string {
	t.Helper()
	parts := make([]string, 0, len(fields))
	for _, f := range fields {
		parts = append(parts, f[0]+"="+url.QueryEscape(f[1]))
	}
	body := strings.Join(parts, "&")
	sum := sha256.Sum256([]byte(body))
	sig, err := ecdsa.SignASN1(rand.Reader, key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%s&signature=%s&key_id=%d", body,
		base64.RawURLEncoding.EncodeToString(sig), keyID)
}

func fields(now time.Time) [][2]string {
	return [][2]string{
		{"ad_network", "5450213213286189855"},
		{"ad_unit", "ca-app-pub-0000000000000000/1111111111"},
		{"custom_data", "b3d4f0c2-0000-4000-8000-000000000001"},
		{"reward_amount", "1"},
		{"reward_item", "diamonds"},
		{"timestamp", fmt.Sprint(now.UnixMilli())},
		{"transaction_id", "7b2c1d4e5f60718293a4b5c6d7e8f900"},
		{"user_id", "0f1e2d3c-0000-4000-8000-00000000000a"},
	}
}

func newVerifier(t *testing.T) (Verifier, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return Verifier{Keys: map[int64]*ecdsa.PublicKey{42: &key.PublicKey}}, key
}

func TestAGenuineCallbackIsRead(t *testing.T) {
	v, key := newVerifier(t)
	now := time.Now().UTC()
	c, err := v.Verify(signed(t, key, 42, fields(now)), now)
	if err != nil {
		t.Fatalf("a callback this server signed itself was refused: %v", err)
	}
	if c.TransactionID != "7b2c1d4e5f60718293a4b5c6d7e8f900" {
		t.Errorf("transaction id came back as %q", c.TransactionID)
	}
	if c.CustomData != "b3d4f0c2-0000-4000-8000-000000000001" || c.UserID != "0f1e2d3c-0000-4000-8000-00000000000a" {
		t.Errorf("the ticket and the lord came back as %q / %q", c.CustomData, c.UserID)
	}
	if c.KeyID != 42 || c.RewardAmount != 1 {
		t.Errorf("key %d, amount %d", c.KeyID, c.RewardAmount)
	}
	if d := now.Sub(c.At); d > time.Second || d < -time.Second {
		t.Errorf("the moment came back %s out", d)
	}
}

// One byte changed anywhere in the query and it is refused. This is the whole
// point of the file: the fields are not to be trusted until this passes.
func TestAChangedFieldIsRefused(t *testing.T) {
	v, key := newVerifier(t)
	now := time.Now().UTC()
	raw := signed(t, key, 42, fields(now))
	for _, swap := range []struct{ from, to string }{
		{"reward_amount=1", "reward_amount=9999"},
		{"user_id=0f1e2d3c", "user_id=0f1e2d3d"},
		{"transaction_id=7b2c", "transaction_id=7b2d"},
		{"custom_data=b3d4", "custom_data=b3d5"},
	} {
		tampered := strings.Replace(raw, swap.from, swap.to, 1)
		if tampered == raw {
			t.Fatalf("the test could not change %q", swap.from)
		}
		if _, err := v.Verify(tampered, now); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s -> %s was accepted: %v", swap.from, swap.to, err)
		}
	}
}

// The query is verified as it ARRIVED. Re-encoding it -- which is what any
// handler that goes through url.Values and back would do -- reorders and
// re-escapes it, and the signature stops matching. Proven here so nobody
// "tidies" the handler into doing it.
func TestTheQueryIsVerifiedExactlyAsItArrived(t *testing.T) {
	v, key := newVerifier(t)
	now := time.Now().UTC()
	raw := signed(t, key, 42, fields(now))
	q, err := url.ParseQuery(raw)
	if err != nil {
		t.Fatal(err)
	}
	// url.Values.Encode sorts by key; AdMob's order is its own.
	if reencoded := q.Encode(); reencoded != raw {
		if _, err := v.Verify(reencoded, now); err == nil {
			t.Error("a re-encoded query verified, so this test proves nothing")
		}
	}
}

func TestAnUnknownKeyIsToldApart(t *testing.T) {
	v, key := newVerifier(t)
	now := time.Now().UTC()
	raw := signed(t, key, 99, fields(now))
	if _, err := v.Verify(raw, now); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("a key id this server has never seen was not told apart: %v", err)
	}
}

func TestAReplayIsRefused(t *testing.T) {
	v, key := newVerifier(t)
	v.MaxAge = time.Hour
	now := time.Now().UTC()
	old := signed(t, key, 42, fields(now.Add(-2*time.Hour)))
	if _, err := v.Verify(old, now); !errors.Is(err, ErrStale) {
		t.Fatalf("a two-hour-old callback was accepted against a one-hour window: %v", err)
	}
	ahead := signed(t, key, 42, fields(now.Add(3*time.Hour)))
	if _, err := v.Verify(ahead, now); !errors.Is(err, ErrStale) {
		t.Fatalf("a callback stamped three hours from now was accepted: %v", err)
	}
}

func TestACallbackWithNothingToPayAgainstIsRefused(t *testing.T) {
	v, key := newVerifier(t)
	now := time.Now().UTC()
	for _, drop := range []string{"transaction_id", "custom_data", "user_id"} {
		f := fields(now)
		for i := range f {
			if f[i][0] == drop {
				f[i][1] = ""
			}
		}
		if _, err := v.Verify(signed(t, key, 42, f), now); !errors.Is(err, ErrInvalid) {
			t.Errorf("a callback with no %s was accepted: %v", drop, err)
		}
	}
}

func TestAQueryWithNoSignatureAtAllIsRefused(t *testing.T) {
	v, _ := newVerifier(t)
	if _, err := v.Verify("ad_unit=x&user_id=y", time.Now()); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a query with no signature was accepted: %v", err)
	}
}

// Google's published keys are PEM, and a rotation adds an id rather than
// changing one. An entry this build cannot read must not cost the others.
func TestAKeySetIsReadAndOneBadKeyDoesNotCostTheRest(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pem := pemOf(t, &key.PublicKey)
	body := fmt.Sprintf(`{"keys":[{"keyId":1,"pem":%q},{"keyId":2,"pem":"not a key"}]}`, pem)
	keys, err := parseKeySet([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[1] == nil {
		t.Fatalf("the readable key did not survive its neighbour: %v", keys)
	}
}

// pemOf writes a public key the way Google publishes one.
func pemOf(t *testing.T, pub *ecdsa.PublicKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
}
