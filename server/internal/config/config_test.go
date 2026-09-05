package config

import (
	"os"
	"testing"
)

// A development seed that changes on every boot invalidates every outstanding
// access token, and a local restart happens constantly. It was signing the
// player out mid-play every time the server came back.
func TestDevSecretsAreStableAcrossBoots(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())    // honoured on Linux
	t.Setenv("HOME", t.TempDir())              // and this is what darwin uses

	first, err := devSecret("token_seed")
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	if len(first) != 32 {
		t.Fatalf("want 32 bytes, got %d", len(first))
	}
	second, err := devSecret("token_seed")
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if string(first) != string(second) {
		t.Fatal("the development seed changed between calls, which logs every player out on restart")
	}

	// Different names must not collide: the shop secret is not the signing key.
	other, err := devSecret("shop_secret")
	if err != nil {
		t.Fatalf("other: %v", err)
	}
	if string(other) == string(first) {
		t.Fatal("the shop secret and the token seed are the same value")
	}
}

// The cached development secret must never become the production key. prod has
// to fail loudly instead.
func TestProdRefusesToInventSecrets(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("EMPERORS_ENV", "prod")
	t.Setenv("DATABASE_URL", "postgres://example/db")
	t.Setenv("DATABASE_URL_DIRECT", "postgres://example/db")
	os.Unsetenv("EMPERORS_TOKEN_SEED")
	os.Unsetenv("EMPERORS_SHOP_SECRET")

	_, err := Load()
	if err == nil {
		t.Fatal("prod accepted a configuration with no token seed and no shop secret")
	}
	for _, want := range []string{"EMPERORS_TOKEN_SEED", "EMPERORS_SHOP_SECRET"} {
		if !contains(err.Error(), want) {
			t.Errorf("the error does not mention %s: %v", want, err)
		}
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
