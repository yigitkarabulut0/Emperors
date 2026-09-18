package iap

import "time"

// Environments a transaction can come from.
const (
	EnvProduction = "Production"
	EnvSandbox    = "Sandbox"
	// Xcode's StoreKit test environment signs with a local certificate that
	// never chains to Apple; it is refused like any other stranger.
	EnvXcode = "Xcode"
)

// Product types, as the App Store names them.
const (
	TypeConsumable      = "Consumable"
	TypeNonConsumable   = "Non-Consumable"
	TypeAutoRenewable   = "Auto-Renewable Subscription"
	TypeNonRenewingSubs = "Non-Renewing Subscription"
)

// Notification types this server acts on (App Store Server Notifications V2).
const (
	NotifySubscribed            = "SUBSCRIBED"
	NotifyDidRenew              = "DID_RENEW"
	NotifyDidFailToRenew        = "DID_FAIL_TO_RENEW"
	NotifyDidChangeRenewalState = "DID_CHANGE_RENEWAL_STATUS"
	NotifyExpired               = "EXPIRED"
	NotifyGracePeriodExpired    = "GRACE_PERIOD_EXPIRED"
	NotifyRefund                = "REFUND"
	NotifyRefundReversed        = "REFUND_REVERSED"
	NotifyRevoke                = "REVOKE"
	NotifyConsumptionRequest    = "CONSUMPTION_REQUEST"
	NotifyTest                  = "TEST"
	NotifyOneTimeCharge         = "ONE_TIME_CHARGE"
)

// Transaction is a verified JWSTransactionDecodedPayload: what was bought, by
// whom (the appAccountToken the client set to the player's id), and when.
// Times are milliseconds since the epoch in the payload; the accessors turn
// them into time.Time.
type Transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	WebOrderLineItemID    string `json:"webOrderLineItemId,omitempty"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	SubscriptionGroupID   string `json:"subscriptionGroupIdentifier,omitempty"`
	PurchaseDateMS        int64  `json:"purchaseDate"`
	OriginalPurchaseMS    int64  `json:"originalPurchaseDate"`
	ExpiresDateMS         int64  `json:"expiresDate,omitempty"`
	Quantity              int    `json:"quantity"`
	Type                  string `json:"type"`
	AppAccountToken       string `json:"appAccountToken,omitempty"`
	InAppOwnershipType    string `json:"inAppOwnershipType"`
	SignedDateMS          int64  `json:"signedDate"`
	RevocationDateMS      int64  `json:"revocationDate,omitempty"`
	RevocationReason      *int   `json:"revocationReason,omitempty"`
	IsUpgraded            bool   `json:"isUpgraded,omitempty"`
	OfferType             int    `json:"offerType,omitempty"`
	Environment           string `json:"environment"`
	Storefront            string `json:"storefront,omitempty"`
	TransactionReason     string `json:"transactionReason,omitempty"`
	// In the storefront's currency, in milliunits (4.99 USD is 4990).
	Price    int64  `json:"price,omitempty"`
	Currency string `json:"currency,omitempty"`
}

func ms(v int64) time.Time {
	if v == 0 {
		return time.Time{}
	}
	return time.UnixMilli(v).UTC()
}

func (t *Transaction) PurchaseDate() time.Time   { return ms(t.PurchaseDateMS) }
func (t *Transaction) ExpiresDate() time.Time    { return ms(t.ExpiresDateMS) }
func (t *Transaction) SignedDate() time.Time     { return ms(t.SignedDateMS) }
func (t *Transaction) RevocationDate() time.Time { return ms(t.RevocationDateMS) }

// Revoked reports whether Apple has refunded or revoked this transaction.
func (t *Transaction) Revoked() bool { return t.RevocationDateMS != 0 }

// Renewal is a verified JWSRenewalInfoDecodedPayload.
type Renewal struct {
	OriginalTransactionID  string `json:"originalTransactionId"`
	AutoRenewProductID     string `json:"autoRenewProductId"`
	ProductID              string `json:"productId"`
	AutoRenewStatus        int    `json:"autoRenewStatus"`
	IsInBillingRetryPeriod bool   `json:"isInBillingRetryPeriod,omitempty"`
	GracePeriodExpiresMS   int64  `json:"gracePeriodExpiresDate,omitempty"`
	ExpirationIntent       int    `json:"expirationIntent,omitempty"`
	SignedDateMS           int64  `json:"signedDate"`
	Environment            string `json:"environment"`
	RenewalDateMS          int64  `json:"renewalDate,omitempty"`
}

func (r *Renewal) SignedDate() time.Time         { return ms(r.SignedDateMS) }
func (r *Renewal) GracePeriodExpires() time.Time { return ms(r.GracePeriodExpiresMS) }

// Notification is a verified App Store Server Notification V2, with the
// transaction and renewal it carries already verified in their own right.
type Notification struct {
	Type         string `json:"notificationType"`
	Subtype      string `json:"subtype,omitempty"`
	UUID         string `json:"notificationUUID"`
	Version      string `json:"version"`
	SignedDateMS int64  `json:"signedDate"`
	Data         struct {
		AppAppleID            int64  `json:"appAppleId,omitempty"`
		BundleID              string `json:"bundleId"`
		BundleVersion         string `json:"bundleVersion,omitempty"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo,omitempty"`
		SignedRenewalInfo     string `json:"signedRenewalInfo,omitempty"`
		Status                int    `json:"status,omitempty"`
	} `json:"data"`

	// Filled by the verifier from Data's two signed fields.
	Transaction *Transaction `json:"-"`
	Renewal     *Renewal     `json:"-"`
}

func (n *Notification) SignedDate() time.Time { return ms(n.SignedDateMS) }
