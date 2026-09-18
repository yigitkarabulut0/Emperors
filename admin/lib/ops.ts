/**
 * The complete list of what the browser may ask the Go API to do.
 *
 * An allowlist, not a catch-all proxy, for a specific reason. The panel this
 * replaces exported five server actions with no call sites -- and a "use server"
 * export is a publicly callable endpoint whether or not any UI imports it, so
 * the write surface had drifted away from the write surface anyone had reviewed.
 * Here the surface IS this file. A route not in it is a 404, and adding one is
 * a diff someone reads.
 *
 * Isomorphic on purpose: it holds no secrets, so the client can use the same
 * ids and the same role gates to decide what to render, and the server uses it
 * to decide what to forward. One declaration, two consumers, no drift.
 */
export type Role = "analyst" | "moderator" | "designer" | "owner";

const RANK: Record<Role, number> = { analyst: 0, moderator: 1, designer: 2, owner: 3 };

/** An unknown role gets nothing, rather than silently falling back to analyst. */
export function atLeast(role: string, minimum: Role): boolean {
  const have = RANK[role as Role];
  return have === undefined ? false : have >= RANK[minimum];
}

export const READS = {
  me: { path: "/me", params: [] },
  live: { path: "/live", params: [] },
  dashboard: { path: "/dashboard", params: ["days"] },
  analytics: { path: "/analytics", params: ["days", "online"] },
  browse: {
    path: "/players/browse",
    params: ["q", "state", "bots", "min_level", "sort", "limit", "offset"],
  },
  playerDetail: { path: "/players/detail", params: ["id", "preview"] },
  boosts: { path: "/boosts", params: [] },
  audit: { path: "/audit", params: ["limit"] },
  balance: { path: "/balance", params: [] },
  balanceVersions: { path: "/balance/versions", params: [] },
  playerDiamonds: { path: "/players/diamonds", params: ["id", "limit", "offset"] },
  mailPreview: { path: "/mail/preview", params: ["target", "min_level", "max_level", "active_days"] },
  mailBroadcasts: { path: "/mail/broadcasts", params: ["limit"] },
  jobs: { path: "/jobs", params: [] },
  dev: { path: "/dev", params: [] },
  billingSummary: { path: "/billing/summary", params: ["days"] },
  billingTransactions: { path: "/billing/transactions", params: ["player", "env", "state", "q", "before", "limit"] },
  billingNotifications: { path: "/billing/notifications", params: ["open", "limit"] },
  playerBilling: { path: "/players/billing", params: ["id"] },
  experiments: { path: "/experiments", params: [] },
  promo: { path: "/promo", params: [] },
  promoRedemptions: { path: "/promo/redemptions", params: ["code"] },
  // The realm's calendar: the hourly schedule, the festivals, the season.
  liveopsHourly: { path: "/liveops/hourly", params: [] },
  liveopsFestivals: { path: "/liveops/festivals", params: [] },
  liveopsFestivalBoard: { path: "/liveops/festivals/board", params: ["id"] },
  liveopsSeason: { path: "/liveops/season", params: [] },
  // Rekabet: the arena's ladder, the board's escrow and the Throne.
  depth: { path: "/depth", params: ["hours"] },
  // Krallik Boss ve Savaslari: the beasts standing and the week's wars.
  kingdomWar: { path: "/kingdom-war", params: ["hours"] },
  pvpArena: { path: "/pvp/arena", params: ["limit"] },
  pvpBounties: { path: "/pvp/bounties", params: ["limit"] },
  pvpThrone: { path: "/pvp/throne", params: [] },
  // Sosyal: the halls' moderation queue, one line's room, and the silences.
  modQueue: { path: "/mod/queue", params: ["limit"] },
  modContext: { path: "/mod/context", params: ["id", "span"] },
  modMutes: { path: "/mod/mutes", params: ["limit"] },
} as const satisfies Record<string, { path: string; params: readonly string[] }>;

export type ReadOp = keyof typeof READS;

/**
 * `fields` is a pick-list, not documentation: the handler copies exactly these
 * keys out of the body and drops the rest, so a client cannot smuggle an extra
 * key into a Go json.Decode.
 *
 * `idempotent` decides whether a failed write may offer a Retry button. The
 * currency writes take DELTAS, so a blind retry on an ambiguous timeout would
 * grant twice. Those say so here and the UI refuses to offer it.
 */
export const WRITES = {
  playerState: {
    path: "/players/state", role: "moderator",
    fields: ["player_id", "state", "note"], idempotent: true,
  },
  playerAdjust: {
    path: "/players/adjust", role: "moderator",
    fields: ["player_id", "gold", "diamonds", "xp", "stat_points", "note"], idempotent: false,
  },
  playerLevel: {
    path: "/players/level", role: "designer",
    fields: ["player_id", "level", "note"], idempotent: true,
  },
  playerEnergy: {
    path: "/players/energy", role: "moderator",
    fields: ["player_id", "energy", "note"], idempotent: true,
  },
  playerLuck: {
    path: "/players/luck", role: "designer",
    fields: ["player_id", "luck_bp", "days", "note"], idempotent: true,
  },
  boostCreate: {
    path: "/boosts", role: "designer",
    fields: ["bucket", "amount_bp", "hours", "starts_in_hours", "note"], idempotent: false,
  },
  boostRevoke: {
    path: "/boosts/revoke", role: "designer",
    fields: ["id"], idempotent: true,
  },
  balancePublish: {
    path: "/balance/publish", role: "designer",
    fields: ["document", "note"], idempotent: false,
  },
  balanceRollback: {
    path: "/balance/rollback", role: "designer",
    fields: ["version_id", "reason"], idempotent: true,
  },
  // The floor, not the whole rule: what a letter CARRIES raises the role it
  // needs (see mailRole in features/mail), and admin.Service decides. A letter
  // is a grant, so a blind retry after a timeout would send it twice.
  mailSend: {
    path: "/mail/send", role: "moderator",
    fields: ["target", "player_id", "segment", "sender", "title", "body", "attachments",
      "expires_days", "include_new", "note"],
    idempotent: false,
  },
  mailRevoke: {
    path: "/mail/revoke", role: "designer",
    fields: ["broadcast_id", "note"], idempotent: true,
  },
  // The billing desk. A retry acts on a notification once and says "already
  // processed" after; a take-back of a purchase already undone says so and
  // takes nothing more; a debt already forgiven is "nothing to change". All
  // three are safe to press twice.
  billingRetry: {
    path: "/billing/notifications/retry", role: "moderator",
    fields: ["id"], idempotent: true,
  },
  billingTakeBack: {
    path: "/billing/take-back", role: "designer",
    fields: ["transaction_id", "state", "note"], idempotent: true,
  },
  forgiveDebt: {
    path: "/players/forgive-debt", role: "designer",
    fields: ["player_id", "note"], idempotent: true,
  },
  // Dev tools, a server that is not production only. A warp or a count moves
  // clocks and counters forward, so a blind retry would do it twice.
  devTimeWarp: {
    path: "/dev/timewarp", role: "designer",
    fields: ["player_id", "hours"], idempotent: false,
  },
  devDeeds: {
    path: "/dev/deeds", role: "designer",
    fields: ["player_id", "deed", "n"], idempotent: false,
  },
  devRunJob: {
    path: "/dev/jobs/run", role: "designer",
    fields: ["name"], idempotent: false,
  },
  // Back to the guide's first step: a second press finds it there already.
  devGuide: {
    path: "/dev/guide", role: "designer",
    fields: ["player_id"], idempotent: true,
  },
  // Giving a right already held, or taking back one already gone, is refused
  // as nothing to do: a retry cannot give twice.
  entitlement: {
    path: "/players/entitlement", role: "designer",
    fields: ["player_id", "entitlement", "grant", "note"], idempotent: true,
  },
  // A code is refused a second time under the same name, so a retry after a
  // timeout cannot make two; disabling twice is a no-op.
  promoCreate: {
    path: "/promo", role: "designer",
    fields: ["code", "note", "reward", "max_uses", "expires_days"], idempotent: true,
  },
  promoDisable: {
    path: "/promo/disable", role: "designer",
    fields: ["code", "note"], idempotent: true,
  },
  // The hourly schedule: setting an hour to what it already says changes
  // nothing, so a retry is safe. A festival scheduled twice is refused as a
  // clash with itself, but the first may have landed: no blind retry.
  liveopsSetHour: {
    path: "/liveops/hourly", role: "designer",
    fields: ["hour", "event", "note"], idempotent: true,
  },
  festivalSchedule: {
    path: "/liveops/festivals", role: "designer",
    fields: ["template", "starts_at", "starts_in_hours", "note"], idempotent: false,
  },
  festivalRevoke: {
    path: "/liveops/festivals/revoke", role: "designer",
    fields: ["id"], idempotent: true,
  },
  // A price already withdrawn gives nothing more back and says so, so a retry
  // after a timeout cannot refund twice.
  bountyRevoke: {
    path: "/pvp/bounties/revoke", role: "designer",
    fields: ["id", "note"], idempotent: true,
  },
  // The week is claimed in admin.period_closes and the reign's own key refuses
  // a second crowning, so running it again crowns nobody twice.
  // A line down or back up, and a tongue silenced or freed. Moderator's, and
  // every one is audited with the line's own id: a silence with no name
  // against it is how a hall becomes a rumour about the crown.
  modHide: {
    path: "/mod/hide", role: "moderator",
    fields: ["id", "hide", "note"], idempotent: true,
  },
  modMute: {
    path: "/mod/mute", role: "moderator",
    fields: ["player_id", "minutes", "reason", "note"], idempotent: true,
  },
  modUnmute: {
    path: "/mod/unmute", role: "moderator",
    fields: ["player_id", "note"], idempotent: true,
  },
  // The lords' queue answered: the desk has looked at this lord. What it
  // decided to do is one of the buttons above, or a letter, or nothing.
  modClear: {
    path: "/mod/clear", role: "moderator",
    fields: ["player_id", "note"], idempotent: true,
  },
  throneSettle: {
    path: "/pvp/throne/settle", role: "designer",
    fields: ["note"], idempotent: true,
  },
} as const satisfies Record<
  string,
  { path: string; role: Role; fields: readonly string[]; idempotent: boolean }
>;

export type WriteOp = keyof typeof WRITES;

export function writeRole(op: WriteOp): Role {
  return WRITES[op].role;
}
