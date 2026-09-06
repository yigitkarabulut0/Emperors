import type { LiveBoard, LiveRow } from "@/lib/protocol";
import type { Role } from "@/lib/ops";

export type ConnectionState = "connecting" | "live" | "reconnecting" | "offline";

export type Toast = {
  id: number;
  tone: "ok" | "err";
  text: string;
  detail?: string;
};

export type Connection = {
  state: ConnectionState;
  /** Server boot id. A change means the world restarted; replace, do not merge. */
  epoch: string | null;
  seq: number;
  attempt: number;
  /** When the next reconnect fires, so the UI can count down instead of spinning. */
  nextRetryAt: number | null;
  lastFrameAt: number;
  error: string | null;
};

export type Root = {
  connection: Connection;
  me: { username: string; role: Role } | null;
  board: LiveBoard | null;
  /** Entity key -> when it last changed, so a cell can flash once and settle. */
  flash: Map<string, { at: number; dir: -1 | 0 | 1 }>;
  toasts: Toast[];
  /** Writes in flight, keyed by an id the caller holds. */
  pending: Set<string>;
};

type Key = keyof Root;
type Listener = () => void;

const EMPTY_BOARD: LiveBoard = {
  playing: [], idle: [], count_playing: 0, count_idle: 0,
  registered: 0, offline: 0, reconciling: false, at: "",
};

/**
 * A small external store read through useSyncExternalStore.
 *
 * External is not a stylistic choice here: a websocket writes to this outside
 * React's control, and the data has to outlive component unmounts and route
 * changes -- an operator must be able to start a write in the inspector, move to
 * Events, and still see it settle. Subscriptions are per slice, so a presence
 * frame arriving four times a second does not re-render the balance editor.
 */
export class Store {
  private state: Root;
  private listeners = new Map<Key, Set<Listener>>();
  private toastSeq = 0;

  constructor(initial?: Partial<Root>) {
    this.state = {
      connection: {
        state: "connecting", epoch: null, seq: 0, attempt: 0,
        nextRetryAt: null, lastFrameAt: 0, error: null,
      },
      me: null,
      board: null,
      flash: new Map(),
      toasts: [],
      pending: new Set(),
      ...initial,
    };
  }

  get<K extends Key>(k: K): Root[K] {
    return this.state[k];
  }

  subscribe(k: Key, fn: Listener): () => void {
    let set = this.listeners.get(k);
    if (!set) {
      set = new Set();
      this.listeners.set(k, set);
    }
    set.add(fn);
    return () => set!.delete(fn);
  }

  private set<K extends Key>(k: K, v: Root[K]): void {
    if (this.state[k] === v) return;
    this.state = { ...this.state, [k]: v };
    this.listeners.get(k)?.forEach((fn) => fn());
  }

  patchConnection(p: Partial<Connection>): void {
    this.set("connection", { ...this.state.connection, ...p });
  }

  setMe(me: Root["me"]): void {
    this.set("me", me);
  }

  /** Replaces the board wholesale. Used by hello and by any full refetch. */
  setBoard(b: LiveBoard | null): void {
    this.set("board", b ?? EMPTY_BOARD);
  }

  /** A player appeared. Idempotent: a join for someone already shown updates
   *  them rather than duplicating the row. */
  playersJoined(rows: LiveRow[]): void {
    const b = this.state.board ?? EMPTY_BOARD;
    const ids = new Set(rows.map((r) => r.id));
    const playing = [...rows.filter((r) => r.presence === "playing"),
                     ...b.playing.filter((r) => !ids.has(r.id))];
    const idle = [...rows.filter((r) => r.presence === "idle"),
                  ...b.idle.filter((r) => !ids.has(r.id))];
    this.setBoard({
      ...b, playing, idle,
      count_playing: playing.length, count_idle: idle.length,
      offline: Math.max(0, b.registered - playing.length - idle.length),
    });
    const now = Date.now();
    const flash = new Map(this.state.flash);
    for (const r of rows) flash.set("join:" + r.id, { at: now, dir: 1 });
    this.set("flash", flash);
  }

  playerLeft(id: string): void {
    const b = this.state.board ?? EMPTY_BOARD;
    const playing = b.playing.filter((r) => r.id !== id);
    const idle = b.idle.filter((r) => r.id !== id);
    this.setBoard({
      ...b, playing, idle,
      count_playing: playing.length, count_idle: idle.length,
      offline: Math.max(0, b.registered - playing.length - idle.length),
    });
  }

  setCounts(c: { playing: number; idle: number; reconciling: boolean }): void {
    const b = this.state.board ?? EMPTY_BOARD;
    this.setBoard({ ...b, reconciling: c.reconciling });
  }

  toast(tone: Toast["tone"], text: string, detail?: string): number {
    const id = ++this.toastSeq;
    this.set("toasts", [...this.state.toasts, { id, tone, text, detail }]);
    // Successes clear themselves; failures stay until dismissed, because the
    // operator has to be able to read what went wrong.
    if (tone === "ok") setTimeout(() => this.dismiss(id), 5000);
    return id;
  }

  dismiss(id: number): void {
    this.set("toasts", this.state.toasts.filter((t) => t.id !== id));
  }

  startPending(id: string): void {
    const next = new Set(this.state.pending);
    next.add(id);
    this.set("pending", next);
  }

  endPending(id: string): void {
    const next = new Set(this.state.pending);
    next.delete(id);
    this.set("pending", next);
  }
}
