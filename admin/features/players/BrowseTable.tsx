"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState, useTransition } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { query, useMutate, useSlice, useStore } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { atLeast } from "@/lib/ops";
import { gold, shortDate, bp } from "@/lib/format";
import s from "./players.module.css";

type PlayerRow = {
  id: string; username: string; name: string; level: number;
  gold: string; diamonds: number; state: string; is_bot: boolean;
  luck_bp: number; created: string; last_seen: string;
};
type Browse = { players: PlayerRow[]; total: number; limit: number; offset: number };

const PAGE = 50;

export function BrowseTable() {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  const me = useSlice("me");
  const board = useSlice("board");
  const store = useStore();
  const mutate = useMutate();
  const [, startNav] = useTransition();

  const [data, setData] = useState<Browse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const q = params.get("q") ?? "";
  const state = params.get("state") ?? "";
  const bots = params.get("bots") ?? "";
  const minLevel = params.get("min_level") ?? "";
  const sort = params.get("sort") ?? "last_seen";
  const offset = Number(params.get("offset") ?? 0);

  const load = useCallback(async () => {
    setLoading(true);
    const res = await query<Browse>("browse", {
      q, state, bots, min_level: minLevel, sort, limit: PAGE, offset,
    });
    if (res.ok) { setData(res.data); setError(null); }
    else setError(res.message);
    setLoading(false);
  }, [q, state, bots, minLevel, sort, offset]);

  useEffect(() => { void load(); }, [load]);

  // Who is in the game right now, so the list can show presence without a
  // second request. The set comes from the same socket the Live board uses.
  const present = useMemo(() => {
    const m = new Map<string, "playing" | "idle">();
    board?.playing.forEach((r) => m.set(r.id, "playing"));
    board?.idle.forEach((r) => m.set(r.id, "idle"));
    return m;
  }, [board]);

  function setParam(patch: Record<string, string>) {
    const next = new URLSearchParams(params.toString());
    for (const [k, v] of Object.entries(patch)) {
      if (v) next.set(k, v); else next.delete(k);
    }
    // Any filter change resets the page; staying on page 4 of a different query
    // is never what anyone meant.
    if (!("offset" in patch)) next.delete("offset");
    startNav(() => router.replace(`${pathname}?${next}`, { scroll: false }));
  }

  async function grant(p: PlayerRow, amount: number) {
    const res = await mutate<{ player: PlayerRow }>("playerAdjust", {
      player_id: p.id, gold: amount, note: "quick grant from the players list",
    }, { key: "grant:" + p.id, success: `${amount > 0 ? "+" : ""}${gold(amount)} gold to ${p.username}` });
    if (res.ok && data) {
      const updated = (res.data as { player?: PlayerRow }).player;
      if (updated) {
        setData({ ...data, players: data.players.map((r) => (r.id === p.id ? { ...r, ...updated } : r)) });
      }
    }
  }

  async function setState(p: PlayerRow, to: string) {
    const res = await mutate<{ player: PlayerRow }>("playerState", {
      player_id: p.id, state: to, note: `${to} from the players list`,
    }, { key: "state:" + p.id, success: `${p.username} is now ${to}` });
    if (res.ok && data) {
      const updated = (res.data as { player?: PlayerRow }).player;
      if (updated) {
        setData({ ...data, players: data.players.map((r) => (r.id === p.id ? { ...r, ...updated } : r)) });
      }
    }
  }

  const canModerate = me ? atLeast(me.role, "moderator") : false;
  const pending = useSlice("pending");

  return (
    <div className={s.page}>
      <Panel title="Find a player">
        <div className={s.filters}>
          <input
            className={s.search}
            placeholder="name or username"
            defaultValue={q}
            onKeyDown={(e) => { if (e.key === "Enter") setParam({ q: (e.target as HTMLInputElement).value }); }}
          />
          <select value={state} onChange={(e) => setParam({ state: e.target.value })}>
            <option value="">any state</option>
            <option value="active">active</option>
            <option value="banned">banned</option>
          </select>
          <select value={bots} onChange={(e) => setParam({ bots: e.target.value })}>
            <option value="">people only</option>
            <option value="1">include bots</option>
          </select>
          <input
            type="number" placeholder="min level" defaultValue={minLevel} style={{ width: 96 }}
            onKeyDown={(e) => { if (e.key === "Enter") setParam({ min_level: (e.target as HTMLInputElement).value }); }}
          />
          <select value={sort} onChange={(e) => setParam({ sort: e.target.value })}>
            <option value="last_seen">last seen</option>
            <option value="created">newest</option>
            <option value="level">level</option>
            <option value="gold">gold</option>
          </select>
          <div className={s.spacer} />
          <Button variant="quiet" size="sm" onClick={() => startNav(() => router.replace(pathname))}>
            clear
          </Button>
        </div>
      </Panel>

      <Panel
        title="Players"
        flush
        actions={
          <div className={s.pager}>
            <span className={s.range}>
              {data ? `${data.total === 0 ? 0 : offset + 1}–${Math.min(offset + PAGE, data.total)} of ${data.total}` : "—"}
            </span>
            <Button size="sm" disabled={offset === 0} onClick={() => setParam({ offset: String(Math.max(0, offset - PAGE)) })}>
              prev
            </Button>
            <Button size="sm" disabled={!data || offset + PAGE >= data.total} onClick={() => setParam({ offset: String(offset + PAGE) })}>
              next
            </Button>
          </div>
        }
      >
        {error ? (
          <EmptyState title="Could not load players"><span className="u-faint">{error}</span></EmptyState>
        ) : loading && !data ? (
          <div style={{ padding: "var(--s6)", display: "grid", gap: "var(--s4)" }}>
            {Array.from({ length: 8 }, (_, i) => <Skeleton key={i} h={20} />)}
          </div>
        ) : !data || data.players.length === 0 ? (
          <EmptyState title={q ? `Nobody matches “${q}”` : "No players yet"}>
            {q && <Button size="sm" onClick={() => setParam({ q: "" })}>clear the search</Button>}
          </EmptyState>
        ) : (
          <TableWrap>
            <Table>
              <thead>
                <tr>
                  <th style={{ width: 18 }} />
                  <th>player</th>
                  <th className={numCell}>lvl</th>
                  <th className={numCell}>gold</th>
                  <th className={numCell}>gems</th>
                  <th>fortune</th>
                  <th>state</th>
                  <th>last seen</th>
                  {canModerate && <th>quick grant</th>}
                </tr>
              </thead>
              <tbody>
                {data.players.map((p) => {
                  const here = present.get(p.id);
                  return (
                    <tr key={p.id}>
                      <td>
                        <i
                          className={`${s.dot} ${here === "playing" ? s.dotPlaying : here === "idle" ? s.dotIdle : s.dotOff}`}
                          title={here ? `in the game (${here})` : "not in the game"}
                        />
                      </td>
                      <td>
                        <Link href={`/players/${p.id}`} className={s.name}>
                          <span>{p.name || p.username}</span>
                          <span className={s.nameSub}>
                            @{p.username}{p.is_bot ? " · bot" : ""}
                          </span>
                        </Link>
                      </td>
                      <td className={numCell}>{p.level}</td>
                      <td className={numCell} style={{ color: "var(--gold-3)" }} title={p.gold}>{gold(p.gold)}</td>
                      <td className={numCell}>{p.diamonds}</td>
                      <td>{p.luck_bp ? <Pill tone="gold">{bp(p.luck_bp)}</Pill> : <span className="u-faint">—</span>}</td>
                      <td>
                        {p.state === "active"
                          ? <Pill tone="ok" dot>active</Pill>
                          : <Pill tone="bad" dot hollow>{p.state}</Pill>}
                      </td>
                      <td className="u-faint">{shortDate(p.last_seen)}</td>
                      {canModerate && (
                        <td>
                          <div className={s.grant}>
                            <Button size="sm" busy={pending.has("grant:" + p.id)} onClick={() => grant(p, 1000)}>
                              +1k
                            </Button>
                            <Button size="sm" busy={pending.has("grant:" + p.id)} onClick={() => grant(p, 10000)}>
                              +10k
                            </Button>
                            {p.state === "active" ? (
                              <Button
                                size="sm" variant="danger"
                                busy={pending.has("state:" + p.id)}
                                onClick={() => {
                                  if (confirm(`Ban ${p.username}? They lose access immediately.`)) void setState(p, "banned");
                                }}
                              >
                                ban
                              </Button>
                            ) : (
                              <Button size="sm" busy={pending.has("state:" + p.id)} onClick={() => setState(p, "active")}>
                                unban
                              </Button>
                            )}
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          </TableWrap>
        )}
      </Panel>
    </div>
  );
}
