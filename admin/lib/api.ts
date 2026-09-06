/**
 * Server-side client for the Go /admin API.
 *
 * Everything runs on the Next.js server. The browser never holds an admin
 * token: it holds an httpOnly cookie, and this module attaches the real token
 * server-side. That means a script injected into the panel — through a player
 * name rendered somewhere, say — cannot read a credential that grants currency.
 */
import { cookies } from "next/headers";

const BASE = process.env.EMPERORS_ADMIN_API ?? "http://localhost:8081";
export const SESSION_COOKIE = "emperors_admin_session";

export type ApiResult<T> = { ok: true; data: T } | { ok: false; status: number; message: string };

export async function callAdmin<T>(
  path: string,
  init: { method?: string; body?: unknown; token?: string } = {},
): Promise<ApiResult<T>> {
  let token = init.token;
  if (!token) {
    token = (await cookies()).get(SESSION_COOKIE)?.value;
  }

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
  } catch (e) {
    // A connection failure is the single most common thing to hit locally, so
    // say what it actually was rather than rendering an empty page.
    return { ok: false, status: 0, message: `cannot reach the game server at ${BASE}` };
  }

  const text = await res.text();
  let parsed: unknown = {};
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    return { ok: false, status: res.status, message: text.slice(0, 200) };
  }
  if (!res.ok) {
    const p = parsed as { message?: string; code?: string };
    return { ok: false, status: res.status, message: p.message ?? p.code ?? `HTTP ${res.status}` };
  }
  return { ok: true, data: parsed as T };
}

export async function isSignedIn(): Promise<boolean> {
  return Boolean((await cookies()).get(SESSION_COOKIE)?.value);
}

/**
 * Builds a URL back to the players list, preserving the search and carrying a
 * message.
 *
 * Server actions cannot render; they redirect. Without the search term the list
 * would reset to "everyone" every time an action ran, which loses the operator's
 * place in the middle of a job.
 */
export function here(q: string, params: Record<string, string>): string {
  const s = new URLSearchParams();
  if (q) s.set("q", q);
  for (const [k, v] of Object.entries(params)) s.set(k, v);
  const qs = s.toString();
  return "/players" + (qs ? "?" + qs : "");
}
