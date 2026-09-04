package game

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"math/rand/v2"
)

// SeedFor derives a deterministic PRNG seed from a server secret and a set of
// public parameters.
//
// This is what lets the shop have no storage: an offer is a pure function of
// (secret, player, window, reroll, slot), so it can be recomputed identically on
// every request, cannot be rerolled by retrying, and can be replayed later to
// audit exactly what a player was offered.
//
// HMAC rather than a plain hash so the secret cannot be recovered by length
// extension, and so a player who learns their own seeds learns nothing about
// anyone else's.
func SeedFor(secret []byte, parts ...uint64) *rand.Rand {
	mac := hmac.New(sha256.New, secret)
	var buf [8]byte
	for _, p := range parts {
		binary.BigEndian.PutUint64(buf[:], p)
		mac.Write(buf[:])
	}
	sum := mac.Sum(nil)
	return rand.New(rand.NewPCG(
		binary.BigEndian.Uint64(sum[0:8]),
		binary.BigEndian.Uint64(sum[8:16]),
	))
}

// SeedForString mixes a string (a player uuid, say) into a seed.
func SeedForString(secret []byte, s string, parts ...uint64) *rand.Rand {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(s))
	var buf [8]byte
	for _, p := range parts {
		binary.BigEndian.PutUint64(buf[:], p)
		mac.Write(buf[:])
	}
	sum := mac.Sum(nil)
	return rand.New(rand.NewPCG(
		binary.BigEndian.Uint64(sum[0:8]),
		binary.BigEndian.Uint64(sum[8:16]),
	))
}
