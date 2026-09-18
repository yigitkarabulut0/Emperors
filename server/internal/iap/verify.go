package iap

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// ErrInvalid is anything that is not a genuine App Store signature for this
// app: a malformed JWS, a chain that does not end at Apple's root, a missing
// marker, a bad signature. The wrapped message says which.
var ErrInvalid = errors.New("iap: not a valid App Store signature")

// ErrWrongApp is a genuine App Store signature for a different app, or from an
// environment this server does not accept.
var ErrWrongApp = errors.New("iap: signed for another app or environment")

// Apple's marker extensions: the leaf of an App Store signing chain carries
// the first, its intermediate the second. A certificate from any other Apple
// service chains to the same root and must still be refused.
var (
	oidAppStoreLeaf          = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidAppleIntermediateWWDR = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Verifier checks App Store signatures for one app.
type Verifier struct {
	// Root is the certificate every chain must end at: AppleRoot() in
	// production, an iaptest root in tests.
	Root *x509.Certificate
	// BundleID is the app's bundle identifier; a transaction for any other is
	// refused.
	BundleID string
	// AppAppleID is the app's numeric App Store id. Zero skips the check on
	// notifications (the id is known only once the app record exists).
	AppAppleID int64
	// AllowSandbox accepts Sandbox transactions as well as Production ones.
	// App Review and TestFlight purchase in the sandbox against the production
	// server, so the production server must accept them -- and mark them, so
	// they never count as revenue.
	AllowSandbox bool
}

type header struct {
	Alg string   `json:"alg"`
	X5C []string `json:"x5c"`
}

// Transaction verifies a signedTransactionInfo JWS.
func (v *Verifier) Transaction(jws string) (*Transaction, error) {
	var t Transaction
	if err := v.verifyJWS(jws, &t, func() time.Time { return t.SignedDate() }); err != nil {
		return nil, err
	}
	if err := v.checkApp(t.BundleID, t.Environment); err != nil {
		return nil, err
	}
	if t.TransactionID == "" || t.ProductID == "" {
		return nil, fmt.Errorf("%w: a transaction without an id or a product", ErrInvalid)
	}
	return &t, nil
}

// Renewal verifies a signedRenewalInfo JWS.
func (v *Verifier) Renewal(jws string) (*Renewal, error) {
	var r Renewal
	if err := v.verifyJWS(jws, &r, func() time.Time { return r.SignedDate() }); err != nil {
		return nil, err
	}
	if err := v.checkEnvironment(r.Environment); err != nil {
		return nil, err
	}
	return &r, nil
}

// Notification verifies a notification's signedPayload and the transaction and
// renewal inside it. Each inner JWS is verified on its own: the outer
// signature covers the inner strings, not what they claim.
func (v *Verifier) Notification(signedPayload string) (*Notification, error) {
	var n Notification
	if err := v.verifyJWS(signedPayload, &n, func() time.Time { return n.SignedDate() }); err != nil {
		return nil, err
	}
	if n.Type == "" || n.UUID == "" {
		return nil, fmt.Errorf("%w: a notification without a type or an id", ErrInvalid)
	}
	// A TEST notification carries no transaction; everything else names the app.
	if n.Data.BundleID != "" || n.Type != NotifyTest {
		if err := v.checkApp(n.Data.BundleID, n.Data.Environment); err != nil {
			return nil, err
		}
	}
	if v.AppAppleID != 0 && n.Data.AppAppleID != 0 && n.Data.AppAppleID != v.AppAppleID {
		return nil, fmt.Errorf("%w: app %d, want %d", ErrWrongApp, n.Data.AppAppleID, v.AppAppleID)
	}
	if n.Data.SignedTransactionInfo != "" {
		t, err := v.Transaction(n.Data.SignedTransactionInfo)
		if err != nil {
			return nil, fmt.Errorf("the notification's transaction: %w", err)
		}
		n.Transaction = t
	}
	if n.Data.SignedRenewalInfo != "" {
		r, err := v.Renewal(n.Data.SignedRenewalInfo)
		if err != nil {
			return nil, fmt.Errorf("the notification's renewal: %w", err)
		}
		n.Renewal = r
	}
	return &n, nil
}

func (v *Verifier) checkApp(bundle, env string) error {
	if v.BundleID == "" || bundle != v.BundleID {
		return fmt.Errorf("%w: bundle %q, want %q", ErrWrongApp, bundle, v.BundleID)
	}
	return v.checkEnvironment(env)
}

func (v *Verifier) checkEnvironment(env string) error {
	switch env {
	case EnvProduction:
		return nil
	case EnvSandbox:
		if v.AllowSandbox {
			return nil
		}
	}
	return fmt.Errorf("%w: environment %q", ErrWrongApp, env)
}

// verifyJWS proves a compact JWS was signed under the App Store chain and
// decodes its payload into out. signedAt reads the payload's signing time
// after decoding: the chain is judged at the moment Apple signed, as Apple's
// own library does, so a transaction stays verifiable after the leaf that
// signed it has expired -- and a certificate cannot sign outside its validity.
func (v *Verifier) verifyJWS(jws string, out any, signedAt func() time.Time) error {
	if v.Root == nil {
		return fmt.Errorf("%w: no root configured", ErrInvalid)
	}
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return fmt.Errorf("%w: not a compact JWS", ErrInvalid)
	}
	rawHeader, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return fmt.Errorf("%w: header encoding", ErrInvalid)
	}
	var h header
	if err := json.Unmarshal(rawHeader, &h); err != nil {
		return fmt.Errorf("%w: header", ErrInvalid)
	}
	// Only ES256. "none", HS256 and the rest are refused by name, before any
	// key is looked at.
	if h.Alg != "ES256" {
		return fmt.Errorf("%w: alg %q", ErrInvalid, h.Alg)
	}
	if len(h.X5C) != 3 {
		return fmt.Errorf("%w: a chain of %d certificates, want 3", ErrInvalid, len(h.X5C))
	}
	certs := make([]*x509.Certificate, 3)
	for i, s := range h.X5C {
		der, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return fmt.Errorf("%w: certificate %d encoding", ErrInvalid, i)
		}
		if certs[i], err = x509.ParseCertificate(der); err != nil {
			return fmt.Errorf("%w: certificate %d: %v", ErrInvalid, i, err)
		}
	}
	leaf, mid, top := certs[0], certs[1], certs[2]
	if !sameCert(top, v.Root) {
		return fmt.Errorf("%w: the chain does not end at the App Store root", ErrInvalid)
	}
	if !hasExtension(leaf, oidAppStoreLeaf) {
		return fmt.Errorf("%w: the leaf is not an App Store signing certificate", ErrInvalid)
	}
	if !hasExtension(mid, oidAppleIntermediateWWDR) {
		return fmt.Errorf("%w: the intermediate is not Apple's", ErrInvalid)
	}

	rawPayload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return fmt.Errorf("%w: payload encoding", ErrInvalid)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return fmt.Errorf("%w: signature encoding", ErrInvalid)
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return fmt.Errorf("%w: the leaf key is not P-256", ErrInvalid)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return fmt.Errorf("%w: the signature does not match", ErrInvalid)
	}

	// Signed by the leaf: the payload is Apple's words. Decode it, then prove
	// the leaf was Apple's at the moment it signed.
	if err := json.Unmarshal(rawPayload, out); err != nil {
		return fmt.Errorf("%w: payload: %v", ErrInvalid, err)
	}
	at := signedAt()
	if at.IsZero() {
		return fmt.Errorf("%w: no signing time", ErrInvalid)
	}
	roots := x509.NewCertPool()
	roots.AddCert(v.Root)
	inter := x509.NewCertPool()
	inter.AddCert(mid)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots: roots, Intermediates: inter, CurrentTime: at,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return fmt.Errorf("%w: chain at %s: %v", ErrInvalid, at.Format(time.RFC3339), err)
	}
	return nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}
