import { PROTOCOL_VERSION, parseFrame, type HelloData } from "@/lib/protocol";
import type { Store } from "./store";

/**
 * The live connection.
 *
 * Same origin: the socket is opened against this app at /api/stream and Next
 * rewrites the upgrade to the Go admin server, so the httpOnly session cookie
 * rides along on the handshake. There is no second credential to mint, expire,
 * or accidentally leave in a proxy log.
 */
const PATH = "/api/stream";

/** Full jitter, capped. Without the jitter, several open tabs reconnect in
 *  lockstep and hit the server as one spike every time it restarts. */
function backoff(attempt: number): number {
  return Math.random() * Math.min(15_000, 500 * 2 ** attempt);
}

/** No frame for this long means the connection is dead even if the socket has
 *  not noticed. The server pings every 20 seconds. */
const WATCHDOG_MS = 45_000;

export class LiveSocket {
  private ws: WebSocket | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private watchdog: ReturnType<typeof setInterval> | null = null;
  private stopped = false;
  private expectedSeq = 0;

  constructor(private store: Store, private onFatal?: () => void) {}

  start(): void {
    this.stopped = false;
    this.open();
    this.watchdog = setInterval(() => {
      const c = this.store.get("connection");
      if (c.state === "live" && Date.now() - c.lastFrameAt > WATCHDOG_MS) {
        // Nothing has arrived for far longer than the server's ping interval.
        // Tear it down rather than sit on a socket that looks open and is not.
        this.ws?.close(4002, "stale");
      }
    }, 5000);
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    if (this.watchdog) clearInterval(this.watchdog);
    this.ws?.close(1000, "leaving");
    this.ws = null;
  }

  private url(): string {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${location.host}${PATH}`;
  }

  private open(): void {
    if (this.stopped) return;
    const attempt = this.store.get("connection").attempt;
    this.store.patchConnection({
      state: attempt === 0 ? "connecting" : "reconnecting",
      nextRetryAt: null,
    });

    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url());
    } catch (e) {
      this.retry(String(e));
      return;
    }
    this.ws = ws;

    ws.onmessage = (ev) => this.onFrame(String(ev.data));
    ws.onerror = () => {
      // The error event carries nothing useful; onclose follows and does the work.
    };
    ws.onclose = (ev) => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.retry(ev.reason || `closed ${ev.code}`);
    };
  }

  private onFrame(raw: string): void {
    const f = parseFrame(raw);
    if (!f) return;

    const now = Date.now();

    if (f.t === "hello") {
      const d = f.data as HelloData;
      if (d.protocol !== PROTOCOL_VERSION) {
        // Refusing is the honest move: a frame shape we half-understand renders
        // numbers that are subtly wrong, which is worse than not rendering.
        this.store.patchConnection({
          state: "offline",
          error: `this panel speaks protocol ${PROTOCOL_VERSION}, the server speaks ${d.protocol} — reload after deploying`,
        });
        this.stopped = true;
        this.ws?.close(1000, "protocol");
        return;
      }
      this.expectedSeq = f.seq + 1;
      this.store.setMe(d.me as never);
      this.store.setBoard(d.snapshot);
      this.store.patchConnection({
        state: "live", epoch: d.epoch, seq: f.seq, attempt: 0,
        lastFrameAt: now, error: null, nextRetryAt: null,
      });
      return;
    }

    // A gap means a frame was lost, and every later frame is an increment
    // against a state that is now wrong. Reconnecting rebuilds from a fresh
    // snapshot, which is the only recovery that cannot silently diverge.
    if (f.seq !== this.expectedSeq) {
      this.ws?.close(4001, "gap");
      return;
    }
    this.expectedSeq = f.seq + 1;
    this.store.patchConnection({ seq: f.seq, lastFrameAt: now });

    switch (f.t) {
      case "presence.joined":
        this.store.playersJoined((f.data as { players: never[] }).players ?? []);
        break;
      case "presence.left":
        this.store.playerLeft((f.data as { id: string }).id);
        break;
      case "presence.counts":
        this.store.setCounts(f.data as never);
        break;
    }
  }

  private retry(reason: string): void {
    if (this.stopped) return;
    const attempt = this.store.get("connection").attempt + 1;

    if (attempt > 9) {
      this.store.patchConnection({ state: "offline", attempt, error: reason, nextRetryAt: null });
      this.onFatal?.();
      return;
    }
    const delay = backoff(attempt);
    this.store.patchConnection({
      state: "reconnecting", attempt, error: reason,
      nextRetryAt: Date.now() + delay,
    });
    this.timer = setTimeout(() => this.open(), delay);
  }

  /** Manual "reconnect now", from the offline state. */
  reconnect(): void {
    if (this.timer) clearTimeout(this.timer);
    this.stopped = false;
    this.store.patchConnection({ attempt: 0 });
    this.open();
  }
}
