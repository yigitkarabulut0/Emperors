import "server-only";
import type { Result } from "@/lib/result";
import { readSession } from "./session";

/**
 * The only module that talks to the Go admin API.
 *
 * It imports next/headers, which fails the build if it is ever pulled into a
 * "use client" graph. That is not a convention anyone has to remember: it is the
 * compiler refusing to let an admin token reach the browser as readable script
 * state.
 */
const BASE = process.env.EMPERORS_ADMIN_API ?? "http://127.0.0.1:8081";

export function upstreamBase(): string {
  return BASE;
}

export async function callAdmin<T>(
  path: string,
  init: { method?: string; body?: unknown; token?: string } = {},
): Promise<Result<T>> {
  const token = init.token ?? (await readSession());

  let res: Response;
  try {
    res = await fetch(BASE + path, {
      method: init.method ?? "GET",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      cache: "no-store",
    });
  } catch {
    // The most common failure by far while developing, and the old panel
    // answered it with an empty page. Say what could not be reached and where.
    return {
      ok: false,
      status: 0,
      code: "unreachable",
      message: `cannot reach the game server at ${BASE}`,
    };
  }

  const text = await res.text();
  let parsed: unknown = {};
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      return { ok: false, status: res.status, code: "bad_response", message: text.slice(0, 200) };
    }
  }
  if (!res.ok) {
    const p = parsed as { message?: string; code?: string };
    return {
      ok: false,
      status: res.status,
      code: p.code ?? "error",
      message: p.message ?? p.code ?? `HTTP ${res.status}`,
    };
  }
  return { ok: true, data: parsed as T };
}
