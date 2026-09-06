/**
 * The wire format of the live stream. Mirrors internal/adminstream in the Go
 * server; if one side changes shape, PROTOCOL_VERSION changes with it and the
 * panel refuses to run rather than mis-rendering a frame it half-understands.
 */
export const PROTOCOL_VERSION = 1;

export type PresenceState = "playing" | "idle";

/** One player on the live board. */
export type LiveRow = {
  id: string;
  username: string;
  name: string;
  level: number;
  gold: string;
  diamonds: number;
  state: string;
  presence: PresenceState;
  since: string;
  seconds_in: number;
  seconds_ago: number;
  /**
   * True when presence was read off ordinary game traffic rather than an
   * explicit heartbeat, because this player's build predates it. The board
   * shows the difference instead of presenting a guess as a fact.
   */
  inferred: boolean;
  devices: number;
  requests: number;
};

export type LiveBoard = {
  playing: LiveRow[];
  idle: LiveRow[];
  count_playing: number;
  count_idle: number;
  registered: number;
  offline: number;
  /** The process is too young to know who is really here. */
  reconciling: boolean;
  at: string;
};

export type Counts = { playing: number; idle: number; reconciling: boolean };

export type Frame =
  | { t: "hello"; seq: number; at: number; data: HelloData }
  | { t: "presence.joined"; seq: number; at: number; data: { players: LiveRow[] } }
  | { t: "presence.left"; seq: number; at: number; data: { id: string; reason: string } }
  | { t: "presence.counts"; seq: number; at: number; data: Counts }
  | { t: string; seq: number; at: number; data?: unknown };

export type HelloData = {
  protocol: number;
  epoch: string;
  me: { username: string; role: string };
  snapshot: LiveBoard;
};

/** Parses a frame, returning null rather than throwing on anything unexpected. */
export function parseFrame(raw: string): Frame | null {
  try {
    const v = JSON.parse(raw) as Frame;
    if (typeof v?.t !== "string" || typeof v?.seq !== "number") return null;
    return v;
  } catch {
    return null;
  }
}
