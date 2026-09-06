"use server";

/**
 * Every admin write, as a server action that RETURNS its outcome.
 *
 * This file is the client/server seam. It is "use server", so a client
 * component may import these and Next compiles the import to an encrypted
 * action id -- the function body, and everything it closes over, stays on the
 * server. lib/api.ts imports next/headers, so importing it from a "use client"
 * module is a build error: that, not discipline, is what keeps the admin token
 * out of the browser.
 *
 * They return rather than redirect. redirect() re-renders the whole page, which
 * is why every action used to reload, lose the scroll position and throw away
 * whatever else was typed. Returning lets the caller show the outcome next to
 * the control that caused it and update just that row.
 */

import { revalidatePath } from "next/cache";
import { callAdmin } from "@/lib/api";

export type Outcome<T = unknown> =
  | { ok: true; data: T; message: string }
  | { ok: false; message: string };

async function write<T>(path: string, body: unknown, message: string, revalidate?: string): Promise<Outcome<T>> {
  const r = await callAdmin<T>(path, { method: "POST", body });
  // The cache still has to be told, or a later full navigation would render a
  // stale page. It just no longer drives THIS update.
  if (r.ok && revalidate) revalidatePath(revalidate);
  return r.ok ? { ok: true, data: r.data, message } : { ok: false, message: r.message };
}

export async function adjustPlayer(playerID: string, f: {
  gold?: number; diamonds?: number; xp?: number; stat_points?: number; note?: string;
}) {
  return write("/players/adjust", { player_id: playerID, ...f }, "Applied.", "/players");
}

export async function setPlayerLevel(playerID: string, level: number, note: string) {
  return write("/players/level", { player_id: playerID, level, note }, "Level set.", "/players");
}

export async function setPlayerEnergy(playerID: string, energy: number, note: string) {
  return write("/players/energy", { player_id: playerID, energy, note }, "Energy set.", "/players");
}

export async function setPlayerLuck(playerID: string, luck_bp: number, days: number, note: string) {
  return write("/players/luck", { player_id: playerID, luck_bp, days, note }, "Fortune set.", "/players");
}

export async function setPlayerState(playerID: string, state: string, note: string) {
  return write("/players/state", { player_id: playerID, state, note },
    state === "banned" ? "Banned." : "Unbanned.", "/players");
}

export async function createBoost(bucket: string, amount_bp: number, hours: number, note: string) {
  return write("/boosts", { bucket, amount_bp, hours, note }, "Event started.", "/events");
}

export async function revokeBoost(id: number) {
  return write("/boosts/revoke", { id }, "Event ended.", "/events");
}

/** Reads used by client components that refresh in place after a write. */
export async function fetchPlayers(query: string): Promise<Outcome<unknown>> {
  const r = await callAdmin(`/players/browse?${query}`);
  return r.ok ? { ok: true, data: r.data, message: "" } : { ok: false, message: r.message };
}

export async function fetchPlayerDetail(id: string, preview: number): Promise<Outcome<unknown>> {
  const r = await callAdmin(`/players/detail?id=${encodeURIComponent(id)}&preview=${preview}`);
  return r.ok ? { ok: true, data: r.data, message: "" } : { ok: false, message: r.message };
}
