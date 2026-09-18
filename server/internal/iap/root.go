// Package iap verifies what the App Store signs: a purchase's transaction and
// the server notifications that follow it (renewals, refunds, revocations).
//
// Standard library only. A signed transaction is a JWS whose header carries
// its own certificate chain (x5c); nothing in it is trusted until that chain
// is proved to end at Apple's root, the leaf and intermediate carry Apple's
// marker extensions, and the ES256 signature checks against the leaf. The root
// is embedded and pinned by fingerprint, so a certificate handed to us can
// never stand in for it.
package iap

import (
	"bytes"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"os"
	"sync"
)

// AppleRootCA-G3.cer is https://www.apple.com/certificateauthority/AppleRootCA-G3.cer,
// the root the App Store signs under (valid 2014-04-30 to 2039-04-30).
//
//go:embed AppleRootCA-G3.cer
var appleRootDER []byte

// AppleRootG3SHA256 is that certificate's published SHA-256 fingerprint. The
// embedded bytes are checked against it before they are used, so a corrupted
// or substituted file fails loudly instead of trusting something else.
const AppleRootG3SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"

var (
	rootOnce sync.Once
	root     *x509.Certificate
	rootErr  error
)

// AppleRoot is Apple Root CA - G3, verified against its pinned fingerprint.
func AppleRoot() (*x509.Certificate, error) {
	rootOnce.Do(func() {
		sum := sha256.Sum256(appleRootDER)
		if hex.EncodeToString(sum[:]) != AppleRootG3SHA256 {
			rootErr = fmt.Errorf("iap: the embedded Apple root does not match its pinned fingerprint")
			return
		}
		root, rootErr = x509.ParseCertificate(appleRootDER)
	})
	return root, rootErr
}

// sameCert reports whether two certificates are the same bytes.
func sameCert(a, b *x509.Certificate) bool {
	return a != nil && b != nil && bytes.Equal(a.Raw, b.Raw)
}

// LoadRoot is the root purchases are proved against: Apple's, or -- for local
// development only; the config refuses it in prod -- a PEM file minted by
// cmd/iapmint.
func LoadRoot(devPEMPath string) (*x509.Certificate, error) {
	if devPEMPath == "" {
		return AppleRoot()
	}
	raw, err := os.ReadFile(devPEMPath)
	if err != nil {
		return nil, fmt.Errorf("iap: dev root: %w", err)
	}
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("iap: dev root %s is not a PEM certificate", devPEMPath)
	}
	return x509.ParseCertificate(block.Bytes)
}
