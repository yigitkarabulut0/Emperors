"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { compact, gold, num } from "@/lib/format";

// Gold is a Go int64 and arrives as a decimal STRING (see lib/format.ts): the
// sums are done in BigInt, never by adding strings -- `0 + "120"` is "0120".
type Flow = { reason: string; created: string; destroyed: string; entries: number; net: string };
// Diamonds are small enough to be numbers.
type DiamondFlow = { reason: string; class: string; created: number; destroyed: number; entries: number };
type Dash = {
  players: number; bots: number; active_1d: number; active_7d: number; new_1d: number;
  gold_held: string; avg_level: number; balance_version: number;
  flows: Flow[]; diamond_flows: DiamondFlow[];
};

const big = (v: string | number): bigint => {
  try { return BigInt(v); } catch { return BigInt(0); }
};

/** One row of a two-sided balance bar: destroyed to the left of the axis,
 *  created to the right, each as a share of the largest side on the table. */
function Balance({ created, destroyed, max }: { created: number; destroyed: number; max: number }) {
  return (
    <span style={{ display: "flex", alignItems: "center", height: 14 }}>
      <span style={{ flex: 1, display: "flex", justifyContent: "flex-end" }}>
        <span style={{
          width: `${(destroyed / max) * 100}%`, height: 8,
          background: "var(--down)", opacity: 0.75, borderRadius: "2px 0 0 2px",
        }} />
      </span>
      <span style={{ width: 1, height: 14, background: "var(--hair-strong)" }} />
      <span style={{ flex: 1 }}>
        <span style={{
          display: "block", width: `${(created / max) * 100}%`, height: 8,
          background: "var(--up)", opacity: 0.75, borderRadius: "0 2px 2px 0",
        }} />
      </span>
    </span>
  );
}

/** Created above the axis, destroyed below. A single-direction bar chart cannot
 *  express an economy: the question is always whether the two sides balance. */
function Flows({ flows }: { flows: Flow[] }) {
  // Bar lengths only: a Number is exact enough to draw with.
  const max = Math.max(1, ...flows.map((f) => Math.max(Number(f.created), Number(f.destroyed))));
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
            const net = big(f.created) - big(f.destroyed);
            return (
              <tr key={f.reason}>
                <td>{f.reason}</td>
                <td><Balance created={Number(f.created)} destroyed={Number(f.destroyed)} max={max} /></td>
                <td className={numCell} style={{ color: "var(--up)" }} title={f.created}>{compact(f.created)}</td>
                <td className={numCell} style={{ color: "var(--down)" }} title={f.destroyed}>{compact(f.destroyed)}</td>
                <td className={numCell} style={{ color: net > 0 ? "var(--up)" : net < 0 ? "var(--down)" : "var(--text-3)" }} title={net.toString()}>
                  {net > 0 ? "+" : ""}{compact(net.toString())}
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

/** Where a diamond reason sits: what play gives, what money buys, what the
 *  panel grants, what players spend, what refunds take back. */
const CLASS: Record<string, { tone: "ok" | "gold" | "synthetic" | "neutral" | "bad"; label: string }> = {
  earned: { tone: "ok", label: "earned" },
  purchased: { tone: "gold", label: "bought" },
  admin: { tone: "synthetic", label: "panel" },
  spent: { tone: "neutral", label: "spent" },
  refund: { tone: "bad", label: "refund" },
};

function DiamondFlows({ flows }: { flows: DiamondFlow[] }) {
  const max = Math.max(1, ...flows.map((f) => Math.max(f.created, f.destroyed)));
  return (
    <TableWrap>
      <Table>
        <thead>
          <tr>
            <th>reason</th>
            <th>kind</th>
            <th style={{ width: "30%" }}>balance</th>
            <th className={numCell}>created</th>
            <th className={numCell}>destroyed</th>
            <th className={numCell}>net</th>
            <th className={numCell}>entries</th>
          </tr>
        </thead>
        <tbody>
          {flows.map((f) => {
            const net = f.created - f.destroyed;
            const c = CLASS[f.class] ?? { tone: "neutral" as const, label: f.class };
            return (
              <tr key={`${f.class}:${f.reason}`}>
                <td>{f.reason}</td>
                <td><Pill tone={c.tone}>{c.label}</Pill></td>
                <td><Balance created={f.created} destroyed={f.destroyed} max={max} /></td>
                <td className={numCell} style={{ color: "var(--up)" }}>{num(f.created)}</td>
                <td className={numCell} style={{ color: "var(--down)" }}>{num(f.destroyed)}</td>
                <td className={numCell} style={{ color: net > 0 ? "var(--up)" : net < 0 ? "var(--down)" : "var(--text-3)" }}>
                  {net > 0 ? "+" : ""}{num(net)}
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

  const flows = d.flows ?? [];
  const created = flows.reduce((a, f) => a + big(f.created), BigInt(0));
  const destroyed = flows.reduce((a, f) => a + big(f.destroyed), BigInt(0));
  const net = created - destroyed;
  // Whole percent, in BigInt so a large economy cannot lose precision here.
  const sink = created > 0 ? Number((destroyed * BigInt(100)) / created) : 0;

  const gems = d.diamond_flows ?? [];
  const gemsIn = gems.reduce((a, f) => a + f.created, 0);
  const gemsOut = gems.reduce((a, f) => a + f.destroyed, 0);
  const byClass = (k: string) => gems.filter((f) => f.class === k).reduce((a, f) => a + f.created, 0);
  const gemsNet = gemsIn - gemsOut;

  const range = (
    <span className="u-row">
      {[7, 30, 90].map((n) => (
        <Button key={n} size="sm" variant={n === days ? "primary" : "quiet"} onClick={() => setDays(n)}>
          {n}d
        </Button>
      ))}
    </span>
  );

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

      <Panel title={`Where gold comes from and goes, last ${days} days`} flush actions={range}>
        <div style={{ padding: "var(--s5) var(--s6)", borderBottom: "1px solid var(--hair)" }} className="u-dim">
          {gold(created.toString())} created, {gold(destroyed.toString())} destroyed —{" "}
          <strong style={{ color: net > 0 ? "var(--warn)" : "var(--up)" }}>
            {net > 0
              ? `${gold(net.toString())} more gold exists than did`
              : `${gold((-net).toString())} was removed from the economy`}
          </strong>
          . Sinks absorbed {sink}% of what was minted
          {sink < 60 && created > 0 ? " — below about 60% and prices drift upward over weeks." : "."}
        </div>
        {flows.length === 0
          ? <EmptyState title="No gold has moved in this window" />
          : <Flows flows={flows} />}
      </Panel>

      <Panel title={`Where diamonds come from and go, last ${days} days`} flush actions={range}>
        <div style={{ padding: "var(--s5) var(--s6)", borderBottom: "1px solid var(--hair)" }} className="u-dim">
          {num(gemsIn)} diamonds created — {num(byClass("earned"))} earned in play
          {byClass("purchased") > 0 ? `, ${num(byClass("purchased"))} bought` : ""}
          {byClass("admin") > 0 ? `, ${num(byClass("admin"))} granted from the panel` : ""}
          {" "}— and {num(gemsOut)} spent or taken back.{" "}
          <strong style={{ color: gemsNet > 0 ? "var(--warn)" : "var(--up)" }}>
            {gemsNet > 0 ? `${num(gemsNet)} more are held than were` : `${num(-gemsNet)} fewer are held than were`}
          </strong>
          . Every row is the diamond ledger: a created figure is the whole grant, including any
          part that repaid a refund debt.
        </div>
        {gems.length === 0
          ? <EmptyState title="No diamonds have moved in this window" />
          : <DiamondFlows flows={gems} />}
      </Panel>
    </div>
  );
}
