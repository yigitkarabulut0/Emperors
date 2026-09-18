// Command iapmint signs App Store-shaped purchases and notifications under a
// throwaway root, so the whole purchase path can be driven locally without a
// phone, a sandbox account or Apple.
//
//	iapmint init                                   mint a chain into -dir (once)
//	iapmint txn    -player <uuid> -product <id>    print a signed transaction
//	iapmint notify -type REFUND -player ... -id T  print a notification body
//
// A server trusts what it signs only when started with
// EMPERORS_IAP_DEV_ROOT=<dir>/root.pem, which the config refuses in prod. It
// refuses to run with EMPERORS_ENV=prod for the same reason.
//
//	go run ./cmd/iapmint init
//	EMPERORS_IAP_DEV_ROOT=$PWD/tmp/iapdev/root.pem go run ./cmd/api
//	jws=$(go run ./cmd/iapmint txn -player $PID -product com.emperors.game.gems.60)
//	curl -H "Authorization: Bearer $T" -d "{\"jws\":\"$jws\"}" localhost:8080/v1/iap/apple/verify
package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/iap/iaptest"
)

const defaultDir = "tmp/iapdev"

func main() {
	if strings.EqualFold(os.Getenv("EMPERORS_ENV"), "prod") {
		fail("refusing to run with EMPERORS_ENV=prod")
	}
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "init":
		doInit(args)
	case "txn":
		doTxn(args)
	case "notify":
		doNotify(args)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: iapmint init|txn|notify [flags]   (iapmint <cmd> -h for flags)")
	os.Exit(2)
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "iapmint: "+format+"\n", a...)
	os.Exit(1)
}

func doInit(args []string) {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	dir := fs.String("dir", defaultDir, "where the chain is written")
	force := fs.Bool("force", false, "replace an existing chain (every JWS it signed stops verifying)")
	_ = fs.Parse(args)
	if _, err := os.Stat(*dir + "/root.pem"); err == nil && !*force {
		fail("%s already holds a chain; -force replaces it", *dir)
	}
	c, err := iaptest.New(iaptest.Options{})
	if err != nil {
		fail("mint: %v", err)
	}
	if err := c.Save(*dir); err != nil {
		fail("save: %v", err)
	}
	fmt.Printf("minted a chain in %s\nstart the dev server with EMPERORS_IAP_DEV_ROOT=%s/root.pem\n", *dir, *dir)
}

// txnFlags are the fields of a transaction, shared by txn and notify.
type txnFlags struct {
	dir, player, product, id, original, env, bundle string
	expires, age                                    time.Duration
	revoked                                         bool
	priceMilli                                      int64
}

func (t *txnFlags) register(fs *flag.FlagSet) {
	fs.StringVar(&t.dir, "dir", defaultDir, "the chain init wrote")
	fs.StringVar(&t.player, "player", "", "the buyer's player id (the appAccountToken)")
	fs.StringVar(&t.product, "product", "", "store product id, e.g. com.emperors.game.gems.60")
	fs.StringVar(&t.id, "id", "", "transaction id (default: a fresh one)")
	fs.StringVar(&t.original, "original", "", "original transaction id (default: -id); a renewal shares its first purchase's")
	fs.StringVar(&t.env, "env", iap.EnvSandbox, "Sandbox or Production")
	fs.StringVar(&t.bundle, "bundle", "com.emperors.game", "bundle id")
	fs.DurationVar(&t.expires, "expires", 0, "a subscription's end, from now (720h; -1h for one already over); 0 for none")
	fs.DurationVar(&t.age, "age", 0, "how long ago it was bought")
	fs.BoolVar(&t.revoked, "revoked", false, "mark it refunded")
	fs.Int64Var(&t.priceMilli, "price", 0, "price in milliunits of USD (4990 is 4.99); 0 leaves it out")
}

func (t *txnFlags) build(kind string) iap.Transaction {
	if t.product == "" {
		fail("-product is required")
	}
	if t.player != "" {
		if _, err := uuid.Parse(t.player); err != nil {
			fail("-player must be a uuid: %v", err)
		}
	}
	if t.id == "" {
		t.id = freshID()
	}
	if t.original == "" {
		t.original = t.id
	}
	now := time.Now()
	bought := now.Add(-t.age)
	x := iap.Transaction{
		TransactionID: t.id, OriginalTransactionID: t.original, BundleID: t.bundle, ProductID: t.product,
		PurchaseDateMS: bought.UnixMilli(), OriginalPurchaseMS: bought.UnixMilli(), Quantity: 1, Type: kind,
		AppAccountToken: t.player, InAppOwnershipType: "PURCHASED", SignedDateMS: now.UnixMilli(),
		Environment: t.env, Storefront: "USA", TransactionReason: "PURCHASE",
	}
	if t.priceMilli > 0 {
		x.Price, x.Currency = t.priceMilli, "USD"
	}
	if t.expires != 0 {
		x.ExpiresDateMS = now.Add(t.expires).UnixMilli()
		x.SubscriptionGroupID = "crown-patronage"
		x.WebOrderLineItemID = freshID()
	}
	if t.revoked {
		x.RevocationDateMS = now.UnixMilli()
		reason := 0
		x.RevocationReason = &reason
	}
	return x
}

func load(dir string) *iaptest.Chain {
	c, err := iaptest.Load(dir)
	if err != nil {
		fail("load chain from %s (run iapmint init first): %v", dir, err)
	}
	return c
}

func doTxn(args []string) {
	fs := flag.NewFlagSet("txn", flag.ExitOnError)
	var t txnFlags
	t.register(fs)
	kind := fs.String("type", iap.TypeConsumable, "Consumable, Non-Consumable or Auto-Renewable Subscription")
	_ = fs.Parse(args)
	c := load(t.dir)
	x := t.build(*kind)
	jws, err := c.Sign(x)
	if err != nil {
		fail("sign: %v", err)
	}
	fmt.Fprintf(os.Stderr, "transaction %s\n", x.TransactionID)
	fmt.Println(jws)
}

func doNotify(args []string) {
	fs := flag.NewFlagSet("notify", flag.ExitOnError)
	var t txnFlags
	t.register(fs)
	kind := fs.String("kind", iap.TypeConsumable, "the transaction's product type")
	typ := fs.String("type", "", "notification type: REFUND, DID_RENEW, EXPIRED, SUBSCRIBED, REFUND_REVERSED, REVOKE, TEST ...")
	subtype := fs.String("subtype", "", "notification subtype, e.g. VOLUNTARY")
	appID := fs.Int64("app-apple-id", 0, "data.appAppleId; 0 leaves it out")
	_ = fs.Parse(args)
	if *typ == "" {
		fail("-type is required")
	}
	c := load(t.dir)

	n := map[string]any{
		"notificationType": *typ,
		"notificationUUID": uuid.NewString(),
		"version":          "2.0",
		"signedDate":       time.Now().UnixMilli(),
	}
	if *subtype != "" {
		n["subtype"] = *subtype
	}
	data := map[string]any{"bundleId": t.bundle, "environment": t.env}
	if *appID != 0 {
		data["appAppleId"] = *appID
	}
	if *typ != iap.NotifyTest {
		if *typ == iap.NotifyRefund || *typ == iap.NotifyRevoke {
			t.revoked = true
		}
		x := t.build(*kind)
		signed, err := c.Sign(x)
		if err != nil {
			fail("sign transaction: %v", err)
		}
		data["signedTransactionInfo"] = signed
		if x.ExpiresDateMS != 0 {
			renew := 1
			if *typ == iap.NotifyExpired {
				renew = 0
			}
			r := iap.Renewal{OriginalTransactionID: x.OriginalTransactionID, AutoRenewProductID: x.ProductID,
				ProductID: x.ProductID, AutoRenewStatus: renew, SignedDateMS: time.Now().UnixMilli(), Environment: t.env}
			if signed, err = c.Sign(r); err != nil {
				fail("sign renewal: %v", err)
			}
			data["signedRenewalInfo"] = signed
		}
		fmt.Fprintf(os.Stderr, "transaction %s (original %s)\n", x.TransactionID, x.OriginalTransactionID)
	}
	n["data"] = data
	payload, err := c.Sign(n)
	if err != nil {
		fail("sign notification: %v", err)
	}
	body, _ := json.Marshal(map[string]string{"signedPayload": payload})
	fmt.Println(string(body))
}

// freshID is a transaction id in the App Store's shape: fifteen or so digits.
func freshID() string {
	n, err := rand.Int(rand.Reader, big.NewInt(9e14))
	if err != nil {
		fail("random: %v", err)
	}
	return fmt.Sprintf("%d", n.Int64()+1e14)
}
