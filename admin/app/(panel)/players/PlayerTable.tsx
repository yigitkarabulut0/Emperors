"use client";

/**
 * The player list, with writes that happen in place.
 *
 * The rows are client state seeded from the server render, so a grant or a ban
 * updates the one row it touched and flashes it -- no reload, no lost scroll
 * position, and no re-fetch of the other forty-nine rows.
 */

import Link from "next/link";
import { useState } from "react";
import { adjustPlayer, setPlayerState } from "@/app/actions";
import { ActionForm, ActionButton } from "@/app/_ui/Inline";

export type Row = {
  id: string; username: string; name: string; level: number;
  gold: string; diamonds: number; state: string; is_bot: boolean;
  luck_bp: number; created: string; last_seen: string;
};

const n = (v: string | number) => Number(v).toLocaleString("en-US");

export function PlayerTable({ rows }: { rows: Row[] }) {
  const [players, setPlayers] = useState(rows);
  const [flash, setFlash] = useState<string | null>(null);

  // The write endpoints return the updated player, so the row is replaced with
  // what the server actually stored rather than with what we hoped it stored.
  const merge = (id: string) => (r: { ok: boolean; data?: unknown }) => {
    if (!r.ok || !r.data) return;
    const p = r.data as Partial<Row> & { id: string };
    setPlayers((cur) => cur.map((x) => (x.id === id ? { ...x, ...p } : x)));
    setFlash(id);
    setTimeout(() => setFlash((f) => (f === id ? null : f)), 1500);
  };

  if (!players.length) return <p className="empty">Nobody matched.</p>;

  return (
    <table>
      <thead>
        <tr>
          <th>PLAYER</th>
          <th className="num">LEVEL</th>
          <th className="num">GOLD</th>
          <th className="num">GEMS</th>
          <th className="num">FORTUNE</th>
          <th>STATE</th>
          <th className="num">LAST SEEN</th>
          <th>QUICK GRANT</th>
        </tr>
      </thead>
      <tbody>
        {players.map((p) => (
          <tr key={p.id} data-flash={flash === p.id ? "true" : undefined}>
            <td>
              <Link href={`/players/${p.id}`}>{p.name}</Link>
              <div className="faint" style={{ fontSize: 11 }}>
                {p.username}{p.is_bot ? " · bot" : ""} · joined {p.created}
              </div>
            </td>
            <td className="num">{p.level}</td>
            <td className="num">{n(p.gold)}</td>
            <td className="num">{n(p.diamonds)}</td>
            <td className="num">
              {p.luck_bp ? <span className="pill gold">{p.luck_bp > 0 ? "+" : ""}{n(p.luck_bp)}</span> : <span className="faint">—</span>}
            </td>
            <td><span className={p.state === "banned" ? "pill err" : "pill ok"}>{p.state}</span></td>
            <td className="num muted">{p.last_seen}</td>
            <td>
              <div className="row wrap" style={{ gap: 8 }}>
                <ActionForm
                  submit="Grant"
                  onDone={merge(p.id)}
                  run={async (fd) =>
                    adjustPlayer(p.id, {
                      gold: Number(fd.get("gold") || 0),
                      note: String(fd.get("note") || "via panel"),
                    })
                  }
                >
                  <input name="gold" placeholder="± gold" style={{ width: 96 }} />
                  <input name="note" placeholder="reason" style={{ width: 130 }} />
                </ActionForm>
                <ActionButton
                  label={p.state === "banned" ? "Unban" : "Ban"}
                  danger={p.state !== "banned"}
                  confirm={p.state === "banned" ? undefined : `Ban ${p.name}?`}
                  onDone={merge(p.id)}
                  run={() => setPlayerState(p.id, p.state === "banned" ? "active" : "banned", "via panel")}
                />
              </div>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
