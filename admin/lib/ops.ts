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
    fields: ["bucket", "amount_bp", "hours", "note"], idempotent: false,
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
} as const satisfies Record<
  string,
  { path: string; role: Role; fields: readonly string[]; idempotent: boolean }
>;

export type WriteOp = keyof typeof WRITES;

export function writeRole(op: WriteOp): Role {
  return WRITES[op].role;
}
