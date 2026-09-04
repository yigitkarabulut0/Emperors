// Package auth owns identity: password hashing, access tokens and refresh
// token rotation.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"runtime"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters. Tuned for a small VPS: ~64 MB and ~50 ms per hash on one
// core, which is slow enough to make offline cracking expensive and fast enough
// that a login does not feel stalled. Memory is the parameter that actually
// hurts an attacker with GPUs, so it is preferred over raw iterations.
const (
	argonTime    = 2
	argonMemory  = 64 * 1024 // KiB
	argonKeyLen  = 32
	argonSaltLen = 16
)

var (
	ErrInvalidHash    = errors.New("malformed password hash")
	ErrWrongPassword  = errors.New("wrong password")
	ErrPasswordPolicy = errors.New("password does not meet the policy")
)

// HashPassword returns a self-describing PHC-format hash. The parameters travel
// with the hash, so raising them later does not invalidate existing passwords —
// old hashes keep verifying with their own parameters and get upgraded on next
// login.
func HashPassword(password string) (string, error) {
	if err := CheckPasswordPolicy(password); err != nil {
		return "", err
	}
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("read salt: %w", err)
	}
	threads := uint8(runtime.NumCPU())
	if threads > 4 {
		threads = 4
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, threads, argonKeyLen)

	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, threads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

// VerifyPassword checks a password against a stored hash in constant time.
func VerifyPassword(password, encoded string) error {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return ErrInvalidHash
	}

	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return ErrInvalidHash
	}
	var memory, time uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &time, &threads); err != nil {
		return ErrInvalidHash
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return ErrInvalidHash
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return ErrInvalidHash
	}

	got := argon2.IDKey([]byte(password), salt, time, memory, threads, uint32(len(want)))
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ErrWrongPassword
	}
	return nil
}

// CheckPasswordPolicy is deliberately minimal: a length floor and nothing else.
//
// Composition rules ("must contain a symbol") are known to push people toward
// predictable substitutions and to make passwords harder to remember without
// making them harder to guess. Length is the property that actually matters.
func CheckPasswordPolicy(password string) error {
	if n := len([]rune(password)); n < 8 {
		return fmt.Errorf("%w: must be at least 8 characters", ErrPasswordPolicy)
	} else if n > 128 {
		// Bounded so a huge input cannot be used to burn CPU in argon2.
		return fmt.Errorf("%w: must be at most 128 characters", ErrPasswordPolicy)
	}
	return nil
}
