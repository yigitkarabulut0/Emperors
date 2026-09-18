// Package iaptest mints App Store-shaped signatures under a throwaway chain,
// for tests and for local development (cmd/iapmint). Nothing it signs verifies
// against Apple's root: a Verifier trusts it only when handed Chain.Root.
package iaptest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

var (
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Options shape a chain, so tests can build the broken ones too.
type Options struct {
	// OmitLeafMarker / OmitIntermediateMarker leave out Apple's extensions.
	OmitLeafMarker         bool
	OmitIntermediateMarker bool
	// NotBefore / NotAfter bound the leaf; zero means a year either side of now.
	NotBefore, NotAfter time.Time
}

// Chain is a root, an intermediate and a leaf, with the leaf's key.
type Chain struct {
	Root, Intermediate, Leaf *x509.Certificate
	leafKey                  *ecdsa.PrivateKey
}

// New mints a chain shaped like the App Store's.
func New(o Options) (*Chain, error) {
	now := time.Now()
	if o.NotBefore.IsZero() {
		o.NotBefore = now.AddDate(-1, 0, 0)
	}
	if o.NotAfter.IsZero() {
		o.NotAfter = now.AddDate(1, 0, 0)
	}
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	rootTpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "iaptest Root"},
		NotBefore: now.AddDate(-10, 0, 0), NotAfter: now.AddDate(10, 0, 0),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTpl, rootTpl, &rootKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	root, _ := x509.ParseCertificate(rootDER)

	midKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	midTpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "iaptest Intermediate"},
		NotBefore: now.AddDate(-5, 0, 0), NotAfter: now.AddDate(5, 0, 0),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	if !o.OmitIntermediateMarker {
		midTpl.ExtraExtensions = []pkix.Extension{{Id: oidIntermediate, Value: []byte{0x05, 0x00}}}
	}
	midDER, err := x509.CreateCertificate(rand.Reader, midTpl, root, &midKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	mid, _ := x509.ParseCertificate(midDER)

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	leafTpl := &x509.Certificate{
		SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "iaptest Leaf"},
		NotBefore: o.NotBefore, NotAfter: o.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature,
	}
	if !o.OmitLeafMarker {
		leafTpl.ExtraExtensions = []pkix.Extension{{Id: oidLeaf, Value: []byte{0x05, 0x00}}}
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTpl, mid, &leafKey.PublicKey, midKey)
	if err != nil {
		return nil, err
	}
	leaf, _ := x509.ParseCertificate(leafDER)
	return &Chain{Root: root, Intermediate: mid, Leaf: leaf, leafKey: leafKey}, nil
}

// Sign returns payload as a compact ES256 JWS with the chain in its x5c header,
// exactly as the App Store sends one.
func (c *Chain) Sign(payload any) (string, error) {
	return c.SignWithHeader(map[string]any{"alg": "ES256", "x5c": c.X5C()}, payload)
}

// SignWithHeader signs under any header, for tests of headers that must fail.
func (c *Chain) SignWithHeader(header map[string]any, payload any) (string, error) {
	h, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	p, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	signing := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(p)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.leafKey, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// X5C is the chain as the header carries it: leaf, intermediate, root.
func (c *Chain) X5C() []string {
	return []string{
		base64.StdEncoding.EncodeToString(c.Leaf.Raw),
		base64.StdEncoding.EncodeToString(c.Intermediate.Raw),
		base64.StdEncoding.EncodeToString(c.Root.Raw),
	}
}

// Save writes the chain to dir -- root.pem, intermediate.pem, leaf.pem and
// leaf.key -- so a dev server can trust its root and cmd/iapmint can keep
// signing under it across runs.
func (c *Chain) Save(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(c.leafKey)
	if err != nil {
		return err
	}
	for name, block := range map[string]*pem.Block{
		"root.pem":         {Type: "CERTIFICATE", Bytes: c.Root.Raw},
		"intermediate.pem": {Type: "CERTIFICATE", Bytes: c.Intermediate.Raw},
		"leaf.pem":         {Type: "CERTIFICATE", Bytes: c.Leaf.Raw},
		"leaf.key":         {Type: "EC PRIVATE KEY", Bytes: keyDER},
	} {
		if err := os.WriteFile(filepath.Join(dir, name), pem.EncodeToMemory(block), 0o600); err != nil {
			return err
		}
	}
	return nil
}

// Load reads a chain Save wrote.
func Load(dir string) (*Chain, error) {
	read := func(name string) ([]byte, error) {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		b, _ := pem.Decode(raw)
		if b == nil {
			return nil, fmt.Errorf("%s is not PEM", name)
		}
		return b.Bytes, nil
	}
	c := &Chain{}
	for name, into := range map[string]**x509.Certificate{
		"root.pem": &c.Root, "intermediate.pem": &c.Intermediate, "leaf.pem": &c.Leaf,
	} {
		der, err := read(name)
		if err != nil {
			return nil, err
		}
		if *into, err = x509.ParseCertificate(der); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
	}
	der, err := read("leaf.key")
	if err != nil {
		return nil, err
	}
	if c.leafKey, err = x509.ParseECPrivateKey(der); err != nil {
		return nil, fmt.Errorf("leaf.key: %w", err)
	}
	return c, nil
}
