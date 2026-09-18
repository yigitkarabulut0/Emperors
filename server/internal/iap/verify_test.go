package iap_test

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/iap/iaptest"
)

const bundle = "com.emperors.game"

func chain(t *testing.T, o iaptest.Options) *iaptest.Chain {
	t.Helper()
	c, err := iaptest.New(o)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func verifier(c *iaptest.Chain) *iap.Verifier {
	return &iap.Verifier{Root: c.Root, BundleID: bundle, AllowSandbox: true}
}

func txn(signed time.Time) map[string]any {
	return map[string]any{
		"transactionId": "2000000123456789", "originalTransactionId": "2000000123456789",
		"bundleId": bundle, "productId": "com.emperors.game.gems.700",
		"purchaseDate": signed.UnixMilli(), "originalPurchaseDate": signed.UnixMilli(),
		"quantity": 1, "type": iap.TypeConsumable,
		"appAccountToken":    "5f7c4f7a-8f0e-4b9a-9f7e-2b1c3d4e5f60",
		"inAppOwnershipType": "PURCHASED", "signedDate": signed.UnixMilli(),
		"environment": iap.EnvSandbox, "storefront": "TUR", "price": 9990, "currency": "USD",
		"someFieldAppleAddsLater": "ignored",
	}
}

func sign(t *testing.T, c *iaptest.Chain, payload any) string {
	t.Helper()
	s, err := c.Sign(payload)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// The embedded root is Apple Root CA - G3, byte for byte.
func TestTheEmbeddedRootIsApples(t *testing.T) {
	r, err := iap.AppleRoot()
	if err != nil {
		t.Fatal(err)
	}
	if r.Subject.CommonName != "Apple Root CA - G3" || !r.IsCA {
		t.Fatalf("the embedded root is %q (CA %v)", r.Subject.CommonName, r.IsCA)
	}
	if r.NotAfter.Year() != 2039 {
		t.Fatalf("the embedded root expires %v, want 2039", r.NotAfter)
	}
}

// A genuine signature verifies, and says what was bought and by whom.
func TestAGenuineTransactionVerifies(t *testing.T) {
	c := chain(t, iaptest.Options{})
	now := time.Now().Truncate(time.Millisecond)
	got, err := verifier(c).Transaction(sign(t, c, txn(now)))
	if err != nil {
		t.Fatal(err)
	}
	if got.ProductID != "com.emperors.game.gems.700" || got.TransactionID != "2000000123456789" ||
		got.AppAccountToken != "5f7c4f7a-8f0e-4b9a-9f7e-2b1c3d4e5f60" || got.Price != 9990 ||
		!got.PurchaseDate().Equal(now) || got.Environment != iap.EnvSandbox {
		t.Fatalf("decoded %+v", got)
	}
}

// Everything that is not a genuine App Store signature for this app is refused.
func TestForgeriesAreRefused(t *testing.T) {
	c := chain(t, iaptest.Options{})
	other := chain(t, iaptest.Options{})
	now := time.Now()
	good := sign(t, c, txn(now))
	parts := strings.Split(good, ".")

	tampered := func() string {
		p := txn(now)
		p["productId"] = "com.emperors.game.gems.8500"
		forged := sign(t, c, p)
		// The payload of one signature with the signature of another.
		fp := strings.Split(forged, ".")
		return parts[0] + "." + fp[1] + "." + parts[2]
	}()
	none := func() string {
		s, _ := c.SignWithHeader(map[string]any{"alg": "none", "x5c": c.X5C()}, txn(now))
		return s
	}()
	hs := func() string {
		s, _ := c.SignWithHeader(map[string]any{"alg": "HS256", "x5c": c.X5C()}, txn(now))
		return s
	}()
	short := func() string {
		s, _ := c.SignWithHeader(map[string]any{"alg": "ES256", "x5c": c.X5C()[:2]}, txn(now))
		return s
	}()
	// A leaf from one chain presented with another chain's intermediate and root.
	spliced := func() string {
		x := other.X5C()
		x[1], x[2] = c.X5C()[1], c.X5C()[2]
		s, _ := other.SignWithHeader(map[string]any{"alg": "ES256", "x5c": x}, txn(now))
		return s
	}()
	noLeafMarker := sign(t, chain(t, iaptest.Options{OmitLeafMarker: true}), txn(now))
	noMidMarker := sign(t, chain(t, iaptest.Options{OmitIntermediateMarker: true}), txn(now))

	for name, jws := range map[string]string{
		"a payload with another signature": tampered,
		"alg none":                         none,
		"alg HS256":                        hs,
		"a two-certificate chain":          short,
		"another chain's root":             sign(t, other, txn(now)),
		"a spliced chain":                  spliced,
		"no leaf marker":                   noLeafMarker,
		"no intermediate marker":           noMidMarker,
		"not a JWS":                        "not.a.jws.at.all",
		"empty":                            "",
		"garbage signature":                parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(make([]byte, 64)),
	} {
		v := verifier(c)
		if name == "no leaf marker" || name == "no intermediate marker" {
			// Those chains have their own roots; trust them, so the only thing
			// wrong is the missing marker.
			v = &iap.Verifier{Root: rootOf(t, jws), BundleID: bundle, AllowSandbox: true}
		}
		if _, err := v.Transaction(jws); !errors.Is(err, iap.ErrInvalid) {
			t.Errorf("%s: %v, want ErrInvalid", name, err)
		}
	}
}

// A genuine signature for another app, or from the sandbox when the sandbox is
// not accepted, is refused as such.
func TestTheAppAndEnvironmentAreChecked(t *testing.T) {
	c := chain(t, iaptest.Options{})
	now := time.Now()
	p := txn(now)
	p["bundleId"] = "com.someone.else"
	if _, err := verifier(c).Transaction(sign(t, c, p)); !errors.Is(err, iap.ErrWrongApp) {
		t.Fatalf("another app's transaction: %v", err)
	}
	strict := &iap.Verifier{Root: c.Root, BundleID: bundle}
	if _, err := strict.Transaction(sign(t, c, txn(now))); !errors.Is(err, iap.ErrWrongApp) {
		t.Fatalf("a sandbox transaction on a server that refuses the sandbox: %v", err)
	}
	p = txn(now)
	p["environment"] = iap.EnvProduction
	if _, err := strict.Transaction(sign(t, c, p)); err != nil {
		t.Fatalf("a production transaction: %v", err)
	}
	p["environment"] = iap.EnvXcode
	if _, err := verifier(c).Transaction(sign(t, c, p)); !errors.Is(err, iap.ErrWrongApp) {
		t.Fatalf("an Xcode transaction: %v", err)
	}
}

// The chain is judged when Apple signed: an old transaction stays verifiable
// after its leaf expires, and a leaf cannot sign outside its validity.
func TestTheChainIsJudgedAtTheSigningTime(t *testing.T) {
	notBefore := time.Now().AddDate(-2, 0, 0)
	notAfter := time.Now().AddDate(-1, 0, 0)
	c := chain(t, iaptest.Options{NotBefore: notBefore, NotAfter: notAfter})
	if _, err := verifier(c).Transaction(sign(t, c, txn(notBefore.AddDate(0, 6, 0)))); err != nil {
		t.Fatalf("a transaction signed while the leaf was valid: %v", err)
	}
	if _, err := verifier(c).Transaction(sign(t, c, txn(time.Now()))); !errors.Is(err, iap.ErrInvalid) {
		t.Fatalf("a transaction signed after the leaf expired: %v", err)
	}
	p := txn(time.Now())
	delete(p, "signedDate")
	if _, err := verifier(c).Transaction(sign(t, c, p)); !errors.Is(err, iap.ErrInvalid) {
		t.Fatalf("a transaction with no signing time: %v", err)
	}
}

// A notification verifies with the transaction and renewal inside it, each
// checked on its own.
func TestANotificationVerifiesWhatItCarries(t *testing.T) {
	c := chain(t, iaptest.Options{})
	now := time.Now()
	renewal := sign(t, c, map[string]any{
		"originalTransactionId": "1", "autoRenewProductId": "com.emperors.game.patronage.month",
		"productId": "com.emperors.game.patronage.month", "autoRenewStatus": 1,
		"signedDate": now.UnixMilli(), "environment": iap.EnvSandbox,
	})
	outer := func(inner string) map[string]any {
		return map[string]any{
			"notificationType": iap.NotifyRefund, "notificationUUID": "8e0c9b7e-1111-2222-3333-444455556666",
			"version": "2.0", "signedDate": now.UnixMilli(),
			"data": map[string]any{"appAppleId": 6700000000, "bundleId": bundle, "environment": iap.EnvSandbox,
				"signedTransactionInfo": inner, "signedRenewalInfo": renewal},
		}
	}
	n, err := verifier(c).Notification(sign(t, c, outer(sign(t, c, txn(now)))))
	if err != nil {
		t.Fatal(err)
	}
	if n.Type != iap.NotifyRefund || n.Transaction == nil || n.Transaction.ProductID != "com.emperors.game.gems.700" ||
		n.Renewal == nil || n.Renewal.AutoRenewStatus != 1 {
		t.Fatalf("decoded %+v", n)
	}

	// An inner transaction signed by a stranger fails the whole notification.
	stranger := chain(t, iaptest.Options{})
	if _, err := verifier(c).Notification(sign(t, c, outer(sign(t, stranger, txn(now))))); !errors.Is(err, iap.ErrInvalid) {
		t.Fatalf("a notification carrying a forged transaction: %v", err)
	}

	// Another app's id is refused once the app's own id is known.
	v := verifier(c)
	v.AppAppleID = 6700000001
	if _, err := v.Notification(sign(t, c, outer(sign(t, c, txn(now))))); !errors.Is(err, iap.ErrWrongApp) {
		t.Fatalf("another app's notification: %v", err)
	}

	// A TEST notification carries nothing and still verifies.
	test := sign(t, c, map[string]any{"notificationType": iap.NotifyTest, "notificationUUID": "t-1",
		"version": "2.0", "signedDate": now.UnixMilli(), "data": map[string]any{}})
	if n, err := verifier(c).Notification(test); err != nil || n.Transaction != nil {
		t.Fatalf("a TEST notification: %+v %v", n, err)
	}
}

// rootOf returns the root certificate a JWS carries, for chains the test built
// with their own roots.
func rootOf(t *testing.T, jws string) *x509.Certificate {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(strings.Split(jws, ".")[0])
	if err != nil {
		t.Fatal(err)
	}
	var h struct {
		X5C []string `json:"x5c"`
	}
	if err := json.Unmarshal(raw, &h); err != nil || len(h.X5C) != 3 {
		t.Fatalf("header: %v", err)
	}
	der, _ := base64.StdEncoding.DecodeString(h.X5C[2])
	c, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// A chain written to disk and read back signs what the same root verifies, and
// LoadRoot trusts the saved root: the path cmd/iapmint and a dev server share.
func TestASavedChainStillSigns(t *testing.T) {
	c := chain(t, iaptest.Options{})
	dir := t.TempDir()
	if err := c.Save(dir); err != nil {
		t.Fatal(err)
	}
	back, err := iaptest.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	root, err := iap.LoadRoot(dir + "/root.pem")
	if err != nil {
		t.Fatal(err)
	}
	if !root.Equal(c.Root) {
		t.Fatal("LoadRoot read a different root than the one saved")
	}
	jws, err := back.Sign(txn(time.Now()))
	if err != nil {
		t.Fatal(err)
	}
	v := &iap.Verifier{Root: root, BundleID: bundle, AllowSandbox: true}
	if _, err := v.Transaction(jws); err != nil {
		t.Fatalf("a JWS signed by the reloaded chain did not verify: %v", err)
	}
	// And Apple's root still refuses it.
	apple, err := iap.LoadRoot("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := (&iap.Verifier{Root: apple, BundleID: bundle, AllowSandbox: true}).Transaction(jws); !errors.Is(err, iap.ErrInvalid) {
		t.Fatalf("Apple's root accepted a dev signature: %v", err)
	}
}
