package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// Short enough that a leaked access token expires before it is very useful,
	// long enough that a player on a train does not re-authenticate constantly.
	AccessTokenTTL  = 15 * time.Minute
	RefreshTokenTTL = 60 * 24 * time.Hour
	refreshBytes    = 32
)

var (
	ErrTokenInvalid = errors.New("invalid token")
	ErrTokenExpired = errors.New("token expired")
)

// Signer mints and verifies access tokens.
//
// Ed25519 rather than HMAC so that a future admin service, or an offline
// verifier, can check a token with only the public half. It is also small and
// fast, which matters when every request carries one.
type Signer struct {
	priv ed25519.PrivateKey
	pub  ed25519.PublicKey
	now  func() time.Time
}

// NewSigner builds a signer from a 32-byte seed. The seed comes from config and
// must be stable: rotating it logs everyone out.
func NewSigner(seed []byte, now func() time.Time) (*Signer, error) {
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("token seed must be %d bytes, got %d", ed25519.SeedSize, len(seed))
	}
	priv := ed25519.NewKeyFromSeed(seed)
	return &Signer{priv: priv, pub: priv.Public().(ed25519.PublicKey), now: now}, nil
}

// Claims is what an access token carries. Deliberately minimal: an id and the
// standard time bounds. Anything else — level, gold, name — would be a stale
// copy of authoritative state and an invitation to trust it.
type Claims struct {
	jwt.RegisteredClaims
	SessionID string `json:"sid"`
}

// Mint issues an access token for a player.
func (s *Signer) Mint(playerID, sessionID string) (string, time.Time, error) {
	now := s.now()
	exp := now.Add(AccessTokenTTL)
	tok := jwt.NewWithClaims(jwt.SigningMethodEdDSA, Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   playerID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
			NotBefore: jwt.NewNumericDate(now.Add(-30 * time.Second)), // clock skew
			Issuer:    "emperors",
		},
		SessionID: sessionID,
	})
	signed, err := tok.SignedString(s.priv)
	return signed, exp, err
}

// Verify parses and validates an access token, returning the player id.
func (s *Signer) Verify(raw string) (playerID, sessionID string, err error) {
	var c Claims
	// The algorithm is pinned. Without this, a token claiming alg:none or an
	// HMAC token signed with the public key would be accepted — the classic JWT
	// confusion attack.
	_, err = jwt.ParseWithClaims(raw, &c, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodEd25519); !ok {
			return nil, fmt.Errorf("unexpected signing method %v", t.Header["alg"])
		}
		return s.pub, nil
	},
		jwt.WithValidMethods([]string{"EdDSA"}),
		jwt.WithIssuer("emperors"),
		jwt.WithTimeFunc(s.now),
	)
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return "", "", ErrTokenExpired
		}
		return "", "", fmt.Errorf("%w: %v", ErrTokenInvalid, err)
	}
	if c.Subject == "" {
		return "", "", ErrTokenInvalid
	}
	return c.Subject, c.SessionID, nil
}

// NewRefreshToken returns a fresh opaque token and the hash to store.
//
// Refresh tokens are random bytes, not JWTs: they must be revocable, and a
// stateless token cannot be revoked. Only the hash is stored, so a database
// leak does not hand out live sessions.
func NewRefreshToken() (token string, hash []byte, err error) {
	b := make([]byte, refreshBytes)
	if _, err := rand.Read(b); err != nil {
		return "", nil, fmt.Errorf("read refresh token: %w", err)
	}
	token = base64.RawURLEncoding.EncodeToString(b)
	return token, HashRefreshToken(token), nil
}

// HashRefreshToken is the stored form. Plain SHA-256 is correct here and a
// password KDF would be wrong: the input is 256 bits of entropy we generated,
// so there is nothing to brute force, and login latency matters.
func HashRefreshToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}
