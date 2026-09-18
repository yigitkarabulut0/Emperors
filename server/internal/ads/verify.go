// Package ads verifies AdMob's server-side verification callback -- the only
// thing that says a lord actually watched an advert.
//
// The shape of the thing: when a rewarded advert finishes, Google calls a URL
// of ours with a query that ends in two parameters, always in this order:
//
//	...&ad_unit=...&custom_data=...&reward_amount=1&timestamp=1700000000000
//	   &transaction_id=...&user_id=...&signature=<web-safe base64>&key_id=<n>
//
// What is signed is every byte BEFORE "&signature=", exactly as it arrived --
// not the parsed values, and not a re-encoding of them. So the verifier is
// handed the raw query and never a url.Values: re-encoding a query reorders it
// and re-escapes it, and either one breaks the signature. That is the whole
// trap in this file.
//
// The signature is ECDSA over SHA-256 with one of the public keys Google
// publishes at https://www.gstatic.com/admob/reward/verifier-keys.json. The
// keys are fetched once and kept, as the App Store's root is: a rotation adds a
// key id, it does not change an old one.
//
// Pure but for FetchKeys: Verify takes the keys and the moment as parameters,
// so a test signs its own callback with its own key and needs no account, no
// network and no advert.
package ads

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var (
	// ErrInvalid is a callback that is not Google's: a malformed query, a
	// signature that does not check out, a missing field.
	ErrInvalid = errors.New("ads: not a valid AdMob callback")
	// ErrUnknownKey is a callback signed with a key id this server has never
	// seen. It is worth telling apart, because it is what a key rotation looks
	// like and the answer to it is to fetch the key set again.
	ErrUnknownKey = errors.New("ads: signed with a key id this server does not have")
	// ErrStale is a callback older than the verifier allows: a replay.
	ErrStale = errors.New("ads: the callback is too old")
)

// KeysURL is where Google publishes the verifier keys.
const KeysURL = "https://www.gstatic.com/admob/reward/verifier-keys.json"

// Callback is one watched advert, as Google reports it.
type Callback struct {
	AdNetwork string
	AdUnit    string
	// CustomData is the ticket the server handed the client when the watch was
	// started, and UserID is the lord it was handed to. Both are carried by the
	// SDK and come back untouched; the ticket is what the reward is paid
	// against, and the lord is checked against it.
	CustomData string
	UserID     string
	// TransactionID is Google's own id for this watch. It is what makes paying
	// twice impossible: the row is keyed by it.
	TransactionID string
	RewardAmount  int64
	RewardItem    string
	// When Google says the advert finished.
	At time.Time
	// The key that signed it, for a log that has to explain a rotation.
	KeyID int64
}

// Verifier checks callbacks against a key set.
type Verifier struct {
	// Keys are Google's verifier keys by id (FetchKeys), or a test's own.
	Keys map[int64]*ecdsa.PublicKey
	// MaxAge is how old a callback may be and still be paid. Google retries a
	// failed callback for a while, so this is generous; it exists to stop a
	// captured URL being replayed weeks later, not to be exact.
	MaxAge time.Duration
}

// DefaultMaxAge is what a callback may be and still be paid.
const DefaultMaxAge = 24 * time.Hour

// Verify checks one raw query string and returns what it says.
//
// `raw` is r.URL.RawQuery, untouched. `now` is the moment to judge staleness
// against, so nothing here reads the clock.
func (v Verifier) Verify(raw string, now time.Time) (Callback, error) {
	var c Callback
	// Everything before "&signature=" is what was signed. A value can never
	// contain that string -- an ampersand inside one is percent-encoded -- so
	// the first occurrence is the right one.
	cut := strings.Index(raw, "&signature=")
	if cut < 0 {
		return c, fmt.Errorf("%w: no signature", ErrInvalid)
	}
	signed := raw[:cut]

	q, err := url.ParseQuery(raw)
	if err != nil {
		return c, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	keyID, err := strconv.ParseInt(q.Get("key_id"), 10, 64)
	if err != nil {
		return c, fmt.Errorf("%w: key_id is not a number", ErrInvalid)
	}
	pub, ok := v.Keys[keyID]
	if !ok || pub == nil {
		return c, fmt.Errorf("%w: %d", ErrUnknownKey, keyID)
	}

	sig, err := decodeSignature(q.Get("signature"))
	if err != nil {
		return c, fmt.Errorf("%w: signature is not web-safe base64", ErrInvalid)
	}
	sum := sha256.Sum256([]byte(signed))
	if !ecdsa.VerifyASN1(pub, sum[:], sig) {
		return c, fmt.Errorf("%w: the signature does not check out", ErrInvalid)
	}

	// Signed, so the fields can be trusted; what is left is whether they say
	// anything a reward can be paid against.
	ms, err := strconv.ParseInt(q.Get("timestamp"), 10, 64)
	if err != nil {
		return c, fmt.Errorf("%w: timestamp is not a number", ErrInvalid)
	}
	c = Callback{
		AdNetwork: q.Get("ad_network"), AdUnit: q.Get("ad_unit"),
		CustomData: q.Get("custom_data"), UserID: q.Get("user_id"),
		TransactionID: q.Get("transaction_id"), RewardItem: q.Get("reward_item"),
		At: time.UnixMilli(ms).UTC(), KeyID: keyID,
	}
	if n, err := strconv.ParseInt(q.Get("reward_amount"), 10, 64); err == nil {
		c.RewardAmount = n
	}
	if c.TransactionID == "" {
		return c, fmt.Errorf("%w: no transaction_id, so it could be paid twice", ErrInvalid)
	}
	if c.CustomData == "" || c.UserID == "" {
		return c, fmt.Errorf("%w: no ticket or no lord on it", ErrInvalid)
	}
	max := v.MaxAge
	if max <= 0 {
		max = DefaultMaxAge
	}
	// Ahead of us as well as behind: a callback stamped next week is not
	// Google's clock being wrong, it is somebody's.
	if now.Sub(c.At) > max || c.At.Sub(now) > time.Hour {
		return c, fmt.Errorf("%w: stamped %s", ErrStale, c.At.Format(time.RFC3339))
	}
	return c, nil
}

// decodeSignature reads Google's web-safe base64, padded or not.
func decodeSignature(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("empty")
	}
	if b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "=")); err == nil {
		return b, nil
	}
	return base64.URLEncoding.DecodeString(s)
}

// keySet is the shape Google publishes.
type keySet struct {
	Keys []struct {
		KeyID  int64  `json:"keyId"`
		PEM    string `json:"pem"`
		Base64 string `json:"base64"`
	} `json:"keys"`
}

// FetchKeys reads Google's published verifier keys.
//
// The one call in this package that touches the network. It is called at
// start-up and again when a callback arrives signed with a key id we do not
// have, which is what a rotation looks like from here.
func FetchKeys(ctx context.Context, client *http.Client, from string) (map[int64]*ecdsa.PublicKey, error) {
	if from == "" {
		from = KeysURL
	}
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, from, nil)
	if err != nil {
		return nil, err
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ads: fetch verifier keys: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("ads: verifier keys answered %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, keysBodyBytes))
	if err != nil {
		return nil, fmt.Errorf("ads: verifier keys: %w", err)
	}
	return parseKeySet(body)
}

// keysBodyBytes is as much of the key set as this server will read.
const keysBodyBytes = 1 << 20

// parseKeySet is FetchKeys without the network, so a test can prove the
// parsing without one.
func parseKeySet(body []byte) (map[int64]*ecdsa.PublicKey, error) {
	var ks keySet
	if err := json.Unmarshal(body, &ks); err != nil {
		return nil, fmt.Errorf("ads: verifier keys: %w", err)
	}
	out := make(map[int64]*ecdsa.PublicKey, len(ks.Keys))
	for _, k := range ks.Keys {
		pub, err := ParsePublicKey(k.PEM)
		if err != nil {
			// One unreadable key must not cost the rest: a rotation that adds a
			// kind of key this build cannot parse still leaves the old one
			// working.
			continue
		}
		out[k.KeyID] = pub
	}
	if len(out) == 0 {
		return nil, errors.New("ads: verifier keys carried nothing this build can read")
	}
	return out, nil
}

// ParsePublicKey reads one PEM-encoded ECDSA public key.
func ParsePublicKey(s string) (*ecdsa.PublicKey, error) {
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("ads: not a PEM block")
	}
	any, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("ads: public key: %w", err)
	}
	pub, ok := any.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("ads: the key is not an ECDSA key")
	}
	return pub, nil
}
