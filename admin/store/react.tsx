"use client";

import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState,
  useSyncExternalStore,
} from "react";
import { Store, type Root } from "./store";
import { LiveSocket } from "./socket";
import type { Result } from "@/lib/result";
import { WRITES, type WriteOp } from "@/lib/ops";

const Ctx = createContext<{ store: Store; socket: LiveSocket | null } | null>(null);

export function StoreProvider({
  children,
  initial,
}: {
  children: React.ReactNode;
  initial?: Partial<Root>;
}) {
  // Constructed once. useState's initialiser, not useMemo: useMemo is a
  // performance hint and React is free to discard it, which would silently
  // build a second store and split the app's state in half.
  const [store] = useState(() => new Store(initial));
  const socketRef = useRef<LiveSocket | null>(null);
  if (socketRef.current === null && typeof window !== "undefined") {
    socketRef.current = new LiveSocket(store);
  }

  useEffect(() => {
    const s = socketRef.current;
    s?.start();
    return () => s?.stop();
  }, []);

  const value = useMemo(() => ({ store, socket: socketRef.current }), [store]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

function useCtx() {
  const c = useContext(Ctx);
  if (!c) throw new Error("useSlice used outside StoreProvider");
  return c;
}

/** Subscribe to one slice. Per-slice, so a presence frame does not re-render
 *  the balance editor. */
export function useSlice<K extends keyof Root>(k: K): Root[K] {
  const { store } = useCtx();
  return useSyncExternalStore(
    useCallback((cb) => store.subscribe(k, cb), [store, k]),
    useCallback(() => store.get(k), [store, k]),
    useCallback(() => store.get(k), [store, k]),
  );
}

export function useStore(): Store {
  return useCtx().store;
}

export function useSocket(): LiveSocket | null {
  return useCtx().socket;
}

/**
 * Run a write.
 *
 * The pending state lives in the store rather than in the component, so a write
 * started in the inspector is still visibly in flight after navigating to
 * another page -- and so a double tap cannot become two grants.
 */
export function useMutate() {
  const store = useStore();

  return useCallback(
    async function mutate<T>(
      op: WriteOp,
      body: Record<string, unknown>,
      opts: { key?: string; success?: string } = {},
    ): Promise<Result<T>> {
      const key = opts.key ?? op;
      if (store.get("pending").has(key)) {
        return { ok: false, status: 409, code: "busy", message: "that is already running" };
      }
      store.startPending(key);
      try {
        const res = await fetch(`/api/m/${op}`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        });
        const out = (await res.json()) as Result<T>;
        if (out.ok) {
          if (opts.success) store.toast("ok", opts.success);
        } else {
          const retryable = WRITES[op].idempotent;
          store.toast(
            "err",
            out.message,
            // A delta write that timed out may or may not have landed, and
            // offering "retry" on it is how someone grants 2000 gold twice.
            retryable || out.status >= 400
              ? undefined
              : "This changes a balance by a delta, so it is not safe to retry blindly — check the audit trail.",
          );
        }
        return out;
      } catch (e) {
        const out: Result<T> = {
          ok: false, status: 0, code: "unreachable",
          message: "the panel could not reach its own server",
        };
        store.toast("err", out.message, String(e));
        return out;
      } finally {
        store.endPending(key);
      }
    },
    [store],
  );
}

/** A read through the proxy. Never throws. */
export async function query<T>(op: string, params: Record<string, string | number | undefined> = {}): Promise<Result<T>> {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== "") qs.set(k, String(v));
  }
  try {
    const res = await fetch(`/api/q/${op}${qs.toString() ? "?" + qs : ""}`, { cache: "no-store" });
    return (await res.json()) as Result<T>;
  } catch {
    return { ok: false, status: 0, code: "unreachable", message: "the panel could not reach its own server" };
  }
}

/** One shared clock, so two hundred "3s ago" labels re-render once a second
 *  between them instead of two hundred times. */
export function useNowTick(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
