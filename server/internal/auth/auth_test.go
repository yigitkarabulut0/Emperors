package auth

import (
	"crypto/ed25519"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestPasswordRoundTrip(t *testing.T) {
	h, err := HashPassword("correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyPassword("correct horse battery", h); err != nil {
		t.Errorf("correct password rejected: %v", err)
	}
	if err := VerifyPassword("Correct horse battery", h); !errors.Is(err, ErrWrongPassword) {
		t.Errorf("wrong password accepted or wrong error: %v", err)
	}
}

func TestPasswordHashesAreSalted(t *testing.T) {
	a, _ := HashPassword("same password")
	b, _ := HashPassword("same password")
	if a == b {
		t.Error("two hashes of the same password are identical — the salt is not working")
	}
}

func TestPasswordPolicy(t *testing.T) {
	if _, err := HashPassword("short"); !errors.Is(err, ErrPasswordPolicy) {
		t.Error("accepted a 5-character password")
	}
	// Bounded so a huge input cannot be used to burn CPU in argon2.
	if _, err := HashPassword(strings.Repeat("a", 200)); !errors.Is(err, ErrPasswordPolicy) {
		t.Error("accepted a 200-character password")
	}
}

func TestVerifyRejectsMalformedHash(t *testing.T) {
	for _, bad := range []string{"", "plaintext", "$argon2id$broken", "$bcrypt$v=19$m=1,t=1,p=1$aaaa$bbbb"} {
		if err := VerifyPassword("x", bad); !errors.Is(err, ErrInvalidHash) {
			t.Errorf("hash %q gave %v, want ErrInvalidHash", bad, err)
		}
	}
}

func TestNormalizeUsername(t *testing.T) {
	ok := []struct{ in, canon, disp string }{
		{"Karabulut", "karabulut", "Karabulut"},
		{"  Player_1  ", "player_1", "Player_1"},
	}
	for _, c := range ok {
		canon, disp, err := NormalizeUsername(c.in)
		if err != nil || canon != c.canon || disp != c.disp {
			t.Errorf("NormalizeUsername(%q) = %q,%q,%v", c.in, canon, disp, err)
		}
	}

	bad := []string{
		"ab",                   // too short
		"waytoolongusername12", // too long
		"1player",              // must start with a letter
		"has space",
		"has-dash",
		"admin", // reserved
		"Admin", // reserved, case-insensitively
		"Аdmin", // Cyrillic А — renders as "Admin" but is a different string
		"emoji😀name",
	}
	for _, b := range bad {
		if _, _, err := NormalizeUsername(b); err == nil {
			t.Errorf("NormalizeUsername(%q) was accepted", b)
		}
	}
}

func TestAccessTokenRoundTrip(t *testing.T) {
	now := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)
	s, err := NewSigner(make([]byte, ed25519.SeedSize), func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}

	tok, exp, err := s.Mint("player-1", "session-1")
	if err != nil {
		t.Fatal(err)
	}
	if !exp.Equal(now.Add(AccessTokenTTL)) {
		t.Errorf("expiry = %v, want %v", exp, now.Add(AccessTokenTTL))
	}

	pid, sid, err := s.Verify(tok)
	if err != nil || pid != "player-1" || sid != "session-1" {
		t.Fatalf("Verify = %q,%q,%v", pid, sid, err)
	}
}

func TestAccessTokenExpires(t *testing.T) {
	now := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)
	clock := now
	s, _ := NewSigner(make([]byte, ed25519.SeedSize), func() time.Time { return clock })
	tok, _, _ := s.Mint("p", "s")

	clock = now.Add(AccessTokenTTL + time.Minute)
	if _, _, err := s.Verify(tok); !errors.Is(err, ErrTokenExpired) {
		t.Errorf("expired token gave %v, want ErrTokenExpired", err)
	}
}

func TestAccessTokenRejectsForeignKey(t *testing.T) {
	now := time.Now
	seedA := make([]byte, ed25519.SeedSize)
	seedB := make([]byte, ed25519.SeedSize)
	seedB[0] = 1

	a, _ := NewSigner(seedA, now)
	b, _ := NewSigner(seedB, now)

	tok, _, _ := a.Mint("p", "s")
	if _, _, err := b.Verify(tok); err == nil {
		t.Error("a token signed by another key was accepted")
	}
}

func TestAccessTokenRejectsAlgNone(t *testing.T) {
	// The classic JWT confusion attack. jwt.WithValidMethods pins EdDSA; without
	// it an attacker could present an unsigned token and be believed.
	s, _ := NewSigner(make([]byte, ed25519.SeedSize), time.Now)
	// header {"alg":"none","typ":"JWT"}, payload {"sub":"victim"}, empty signature
	forged := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ2aWN0aW0iLCJpc3MiOiJlbXBlcm9ycyJ9."
	if _, _, err := s.Verify(forged); err == nil {
		t.Error("an alg:none token was accepted")
	}
}

func TestRefreshTokenIsHighEntropyAndHashed(t *testing.T) {
	tok, hash, err := NewRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(tok) < 40 {
		t.Errorf("refresh token is only %d chars", len(tok))
	}
	if len(hash) != 32 {
		t.Errorf("hash is %d bytes, want 32", len(hash))
	}
	if strings.Contains(string(hash), tok) {
		t.Error("the stored hash contains the token")
	}

	other, _, _ := NewRefreshToken()
	if tok == other {
		t.Error("two refresh tokens collided")
	}
	// The hash must be deterministic, or lookup by hash cannot work.
	if string(HashRefreshToken(tok)) != string(hash) {
		t.Error("HashRefreshToken is not deterministic")
	}
}
