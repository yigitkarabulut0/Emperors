"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Skeleton, Stat, Stats } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { compact, gold, num } from "@/lib/format";

type Flow = { reason: string; created: number; destroyed: number; entries: number };
type Dash = {
  players: number; bots: number; active_1d: number; active_7d: number; new_1d: number;
  gold_held: number; avg_level: number; balance_version: number; flows: Flow[];
};

/** Created above the axis, destroyed below. A single-direction bar chart cannot
 *  express an economy: the question is always whether the two sides balance. */
function Flows({ flows }: { flows: Flow[] }) {
  const max = Math.max(1, ...flows.map((f) => Math.max(f.created, f.destroyed)));
  return (
    <TableWrap>
      <Table>
        <thead>
          <tr>
            <th>source</th>
            <th style={{ width: "34%" }}>balance</th>
            <th className={numCell}>created</th>
            <th className={numCell}>destroyed</th>
            <th className={numCell}>net</th>
            <th className={numCell}>entries</th>
          </tr>
        </thead>
        <tbody>
          {flows.map((f) => {
            const net = f.created - f.destroyed;
            return (
              <tr key={f.reason}>
                <td>{f.reason}</td>
                <td>
                  <span style={{ display: "flex", alignItems: "center", height: 14 }}>
                    <span style={{ flex: 1, display: "flex", justifyContent: "flex-end" }}>
                      <span style={{
                        width: `${(f.destroyed / max) * 100}%`, height: 8,
                        background: "var(--down)", opacity: 0.75, borderRadius: "2px 0 0 2px",
                      }} />
                    </span>
                    <span style={{ width: 1, height: 14, background: "var(--hair-strong)" }} />
                    <span style={{ flex: 1 }}>
                      <span style={{
                        display: "block", width: `${(f.created / max) * 100}%`, height: 8,
                        background: "var(--up)", opacity: 0.75, borderRadius: "0 2px 2px 0",
                      }} />
                    </span>
                  </span>
                </td>
                <td className={numCell} style={{ color: "var(--up)" }} title={String(f.created)}>{compact(f.created)}</td>
                <td className={numCell} style={{ color: "var(--down)" }} title={String(f.destroyed)}>{compact(f.destroyed)}</td>
                <td className={numCell} style={{ color: net > 0 ? "var(--up)" : net < 0 ? "var(--down)" : "var(--text-3)" }}>
                  {net > 0 ? "+" : ""}{compact(net)}
                </td>
                <td className={numCell} style={{ color: "var(--text-3)" }}>{num(f.entries)}</td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </TableWrap>
  );
}

export function EconomyView() {
  const [days, setDays] = useState(30);
  const [d, setD] = useState<Dash | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (n: number) => {
    const res = await query<Dash>("dashboard", { days: n });
    if (res.ok) { setD(res.data); setError(null); } else setError(res.message);
  }, []);

  useEffect(() => { void load(days); }, [days, load]);

  if (error) return <EmptyState title="Could not load the economy"><span className="u-faint">{error}</span></EmptyState>;
  if (!d) return <div style={{ display: "grid", gap: "var(--s6)" }}><Skeleton h={90} /><Skeleton h={280} /></div>;

  const created = d.flows.reduce((a, f) => a + f.created, 0);
  const destroyed = d.flows.reduce((a, f) => a + f.destroyed, 0);
  const net = created - destroyed;
  const sink = created > 0 ? Math.round((destroyed / created) * 100) : 0;

  return (
    <div style={{ display: "grid", gap: "var(--s6)", maxWidth: 1100 }}>
      <Stats>
        <Stat label="Players" value={num(d.players)} sub={`${num(d.bots)} bots`} />
        <Stat label="Active today" value={num(d.active_1d)} sub={`${num(d.active_7d)} this week`} muted />
        <Stat label="New today" value={num(d.new_1d)} muted />
        <Stat label="Gold held" value={compact(d.gold_held)} title={String(d.gold_held)} />
        <Stat label="Average level" value={d.avg_level?.toFixed(1) ?? "—"} muted />
        <Stat label="Balance version" value={d.balance_version} muted />
      </Stats>

      <Panel
        title={`Where gold comes from and goes, last ${days} days`}
        flush
        actions={
          <span className="u-row">
            {[7, 30, 90].map((n) => (
              <Button key={n} size="sm" variant={n === days ? "primary" : "quiet"} onClick={() => setDays(n)}>
                {n}d
              </Button>
            ))}
          </span>
        }
      >
        <div style={{ padding: "var(--s5) var(--s6)", borderBottom: "1px solid var(--hair)" }} className="u-dim">
          {gold(created)} created, {gold(destroyed)} destroyed —{" "}
          <strong style={{ color: net > 0 ? "var(--warn)" : "var(--up)" }}>
            {net > 0 ? `${gold(net)} more gold exists than did` : `${gold(-net)} was removed from the economy`}
          </strong>
          . Sinks absorbed {sink}% of what was minted
          {sink < 60 && created > 0 ? " — below about 60% and prices drift upward over weeks." : "."}
        </div>
        {d.flows.length === 0
          ? <EmptyState title="No gold has moved in this window" />
          : <Flows flows={d.flows} />}
      </Panel>
    </div>
  );
}
