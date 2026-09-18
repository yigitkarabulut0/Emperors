/** The billing desk's shapes, as internal/admin/billing.go sends them. */

export type GrantLine = { kind: string; id?: string; amount: number; text: string; icon: string };

export type Txn = {
  id: number;
  transaction_id: string;
  original_transaction_id: string;
  player_id: string;
  username: string;
  deleted: boolean;
  product_id: string;
  product_name: string;
  store_product_id: string;
  kind: string;
  environment: "Production" | "Sandbox" | string;
  sandbox: boolean;
  purchased_at: string;
  expires_at: string | null;
  usd_cents: number;
  price_milli: number | null;
  currency: string;
  storefront: string;
  /** What the grant gave, as the reward lines the phone showed; {} before a
   *  grant was recorded (a refund that arrived first). */
  granted: GrantLine[] | Record<string, never>;
  state: "granted" | "refunded" | "revoked" | string;
  refunded_at: string | null;
  refund_note: string;
};

export type Notice = {
  id: number;
  uuid: string;
  type: string;
  subtype: string;
  environment: string;
  transaction_id: string;
  original_transaction_id: string;
  received_at: string;
  processed_at: string | null;
  outcome: string;
  attempts: number;
  last_error: string;
  next_attempt_at: string | null;
  status: "done" | "pending" | "abandoned";
};

export type Summary = {
  days: number;
  gross_cents: number;
  refund_cents: number;
  net_cents: number;
  purchases: number;
  refunds: number;
  revoked: number;
  payers: number;
  arppu_cents: number;
  sandbox_purchases: number;
  sandbox_cents: number;
  active_lords: number;
  /** Net revenue per lord per day played, in hundredths of a cent. */
  arpdau_centicents: number;
  conversion_bp: number;
  pending_notifications: number;
  abandoned_notifications: number;
  daily: { day: string; gross_cents: number; refund_cents: number; purchases: number }[];
  products: { product_id: string; name: string; purchases: number; gross_cents: number; refunds: number; buyers: number }[];
  flagged: { player_id: string; username: string; deleted: boolean; refunds: number; refund_cents: number; last_refund: string }[];
  flag_refunds: number;
  flag_days: number;
  /** The rewarded advert over the same window. Absent on a realm with no adverts. */
  herald?: {
    /** The takings' window cut to what the ad_watches table still holds. */
    days: number;
    started: number;
    paid: number;
    lords: number;
    diamonds: number;
    /** Watches paid over watches started, in basis points. */
    fill_bp: number;
  };
};

export type PlayerBilling = {
  vip_points: number;
  vip_level: number;
  vip_next_at: number;
  patron_until: string | null;
  steward: boolean;
  bag_bonus: number;
  stipend_until: string;
  stipend_claimed: string;
  diamonds: number;
  diamond_debt: number;
  spent_cents: number;
  purchases: number;
  sandbox_purchases: number;
  recent_refunds: number;
  flagged: boolean;
  entitlements: { name: string; transaction_id: string; granted_at: string }[];
  subscriptions: {
    original_transaction_id: string; product_id: string; environment: string;
    status: string; expires_at: string; auto_renew: boolean; updated_at: string;
  }[];
  bought: { product_id: string; name: string; count: number }[];
  offers: { product_id: string; name: string; fired_at: string; expires_at: string; seen_at: string | null }[];
  transactions: Txn[];
};
