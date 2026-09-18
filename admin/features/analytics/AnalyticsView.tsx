"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Skeleton, Stat, Stats } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { num, pctOf, usd } from "@/lib/format";
import { Columns } from "@/ui/Columns";
import s from "./analytics.module.css";

type Point = { day: string; count: number };
type Cohort = { day: string; size: number; d1: number | null; d7: number | null; d30: number | null };
type Count = { name: string; count: number; players: number };
type KPI = {
  day: string; dau: number; new_lords: number; payers: number; purchases: number;
  gross_cents: number; refund_cents: number; net_cents: number; arpdau_centicents: number; conversion_bp: number;
  diamonds_earned: number; diamonds_bought: number; diamonds_spent: number;
};
type Analytics = {
  registrations: Point[]; active: Point[]; level_bands: Point[];
  retention: Cohort[]; events: Count[]; screens: Count[]; sessions: Point[];
  kpis: KPI[]; days: number;
};

/** The rolled-up days: what each finished day came to, money included. */
function DayByDay({ kpis, days }: { kpis: KPI[]; days: number }) {
  const [table, setTable] = useState(true);
  const net = kpis.map((k) => ({ day: k.day, count: k.net_cents }));
  return (
    <Panel
      title="Day by day"
      flush={table}
      actions={kpis.length > 0 && <Button size="sm" variant="quiet" onClick={() => setTable(!table)}>{table ? "net by day" : "table"}</Button>}
    >
      <div style={{ padding: "var(--s5) var(--s6)", borderBottom: table ? "1px solid var(--hair)" : undefined }} className={s.note}>
        Each finished UTC day, rolled up the next morning and twice more after it, so a refund or a delivery that
        lands late is counted on its own day. Money is Production only, in US dollars before Apple&rsquo;s share;
        per lord is net takings over the lords who played that day.
      </div>
      {kpis.length === 0 ? (
        <EmptyState title={`No day of the last ${days} has been rolled up`}>
          <span className="u-faint">The kpi_rollup job writes yesterday each morning at 01:00 UTC.</span>
        </EmptyState>
      ) : table ? (
        <TableWrap>
          <Table>
            <thead>
              <tr>
                <th>day (utc)</th><th className={numCell}>played</th><th className={numCell}>joined</th>
                <th className={numCell}>paid</th><th className={numCell}>of those who played</th>
                <th className={numCell}>net</th><th className={numCell}>per lord</th>
                <th className={numCell}>diamonds earned</th><th className={numCell}>bought</th><th className={numCell}>spent</th>
              </tr>
            </thead>
            <tbody>
              {[...kpis].reverse().map((k) => (
                <tr key={k.day}>
                  <td className="u-mono u-dim">{k.day}</td>
                  <td className={numCell}>{num(k.dau)}</td>
                  <td className={numCell}>{num(k.new_lords)}</td>
                  <td className={numCell}>{num(k.payers)}</td>
                  <td className={numCell} style={{ color: "var(--text-3)" }}>{k.dau ? `${(k.conversion_bp / 100).toFixed(1)}%` : "—"}</td>
                  <td className={numCell} title={`${usd(k.gross_cents)} in · ${usd(k.refund_cents)} refunded`}>{usd(k.net_cents)}</td>
                  <td className={numCell} style={{ color: "var(--text-3)" }}>{k.dau ? `$${(k.arpdau_centicents / 10000).toFixed(4)}` : "—"}</td>
                  <td className={numCell}>{num(k.diamonds_earned)}</td>
                  <td className={numCell}>{num(k.diamonds_bought)}</td>
                  <td className={numCell}>{num(k.diamonds_spent)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableWrap>
      ) : (
        <div style={{ padding: "var(--s5) var(--s6)" }}>
          <Columns points={net} unit={["net", "net"]} format={usd} />
        </div>
      )}
    </Panel>
  );
}

function DailyTable({ points, unit }: { points: Point[]; unit: [string, string] }) {
  return (
    <TableWrap>
      <Table>
        <thead><tr><th>day (utc)</th><th className={numCell}>{unit[1]}</th></tr></thead>
        <tbody>
          {[...points].reverse().map((p) => (
            <tr key={p.day}><td className="u-mono u-dim">{p.day}</td><td className={numCell}>{num(p.count)}</td></tr>
          ))}
        </tbody>
      </Table>
    </TableWrap>
  );
}

/** A daily series with its chart/table switch. */
function Daily({ title, points, unit, children }: {
  title: string; points: Point[]; unit: [string, string]; children?: React.ReactNode;
}) {
  const [table, setTable] = useState(false);
  return (
    <Panel
      title={title}
      flush={table}
      actions={<Button size="sm" variant="quiet" onClick={() => setTable(!table)}>{table ? "chart" : "table"}</Button>}
    >
      {table ? <DailyTable points={points} unit={unit} /> : (
        <div style={{ display: "grid", gap: "var(--s5)" }}>
          <Columns points={points} unit={unit} />
          {children}
        </div>
      )}
    </Panel>
  );
}

/** Counts with a bar each, as a share of the largest. */
function Ranked({ rows, head, unit, empty }: {
  rows: { name: string; count: number; players?: number }[];
  head: string; unit: string; empty: React.ReactNode;
}) {
  if (rows.length === 0) return <>{empty}</>;
  const max = Math.max(1, ...rows.map((r) => r.count));
  const total = rows.reduce((a, r) => a + r.count, 0);
  const players = rows.some((r) => r.players !== undefined);
  return (
    <TableWrap>
      <Table>
        <thead>
          <tr>
            <th>{head}</th>
            <th style={{ width: "36%" }} />
            <th className={numCell}>{unit}</th>
            <th className={numCell}>share</th>
            {players && <th className={numCell}>players</th>}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.name}>
              <td className="u-mono">{r.name || "—"}</td>
              <td><span className={s.barTrack}><span className={s.bar} style={{ width: `${(r.count / max) * 100}%` }} /></span></td>
              <td className={numCell}>{num(r.count)}</td>
              <td className={numCell} style={{ color: "var(--text-3)" }}>{pctOf(r.count, total)}</td>
              {players && <td className={numCell} style={{ color: "var(--text-3)" }}>{num(r.players ?? 0)}</td>}
            </tr>
          ))}
        </tbody>
      </Table>
    </TableWrap>
  );
}

/** One return day of a cohort: the share, with the count beside it, in a cell
 *  whose gold is as strong as the share. Null is "too soon to say", never 0. */
function Heat({ n, size }: { n: number | null; size: number }) {
  if (n === null) return <td className={`${s.heat} ${s.pending}`} title="This day has not come yet for this cohort">—</td>;
  const share = size ? n / size : 0;
  return (
    <td className={s.heat} style={{ background: `color-mix(in oklab, var(--gold-4) ${Math.round(share * 55)}%, transparent)` }}>
      <span className={s.heatPct}>{pctOf(n, size)}</span>
      <span className={s.heatN}>{num(n)}</span>
    </td>
  );
}

/** Retention over every cohort that has reached the day, weighted by size. */
function weighted(cohorts: Cohort[], k: "d1" | "d7" | "d30"): { back: number; of: number } {
  let back = 0, of = 0;
  for (const c of cohorts) {
    const v = c[k];
    if (v !== null) { back += v; of += c.size; }
  }
  return { back, of };
}

export function AnalyticsView() {
  const [days, setDays] = useState(30);
  const [a, setA] = useState<Analytics | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async (n: number) => {
    setLoading(true);
    const res = await query<Analytics>("analytics", { days: n });
    if (res.ok) { setA(res.data); setError(null); } else setError(res.message);
    setLoading(false);
  }, []);

  useEffect(() => { void load(days); }, [days, load]);

  if (error && !a) return <EmptyState title="Could not load the analytics"><span className="u-faint">{error}</span></EmptyState>;
  if (!a) return <div className={s.page}><Skeleton h={90} /><Skeleton h={200} /><Skeleton h={240} /></div>;

  const joined = a.registrations.reduce((t, p) => t + p.count, 0);
  const today = a.active.length ? a.active[a.active.length - 1].count : 0;
  const avgActive = a.active.length ? a.active.reduce((t, p) => t + p.count, 0) / a.active.length : 0;
  const d1 = weighted(a.retention, "d1");
  const d7 = weighted(a.retention, "d7");
  const d30 = weighted(a.retention, "d30");
  const sessions = a.sessions.reduce((t, p) => t + p.count, 0);

  return (
    <div className={`${s.page} ${loading ? s.refetching : ""}`}>
      {/* One row of filters, above everything it scopes. */}
      <div className={s.filters}>
        <span className="u-micro">window</span>
        {[7, 30, 90].map((n) => (
          <Button key={n} size="sm" variant={n === days ? "primary" : "quiet"} onClick={() => setDays(n)}>
            {n}d
          </Button>
        ))}
        {error && <span className="u-down" style={{ fontSize: "var(--t-small)" }}>{error}</span>}
      </div>

      <Stats>
        <Stat label="Joined" value={num(joined)} sub={`in ${a.days} days`} />
        <Stat label="Played today" value={num(today)} sub={`${avgActive < 10 ? avgActive.toFixed(1) : num(avgActive)} a day on average`} muted />
        <Stat
          label="Back next day"
          value={pctOf(d1.back, d1.of)}
          sub={d1.of ? `${num(d1.back)} of ${num(d1.of)} who joined` : "no cohort has reached day 1"}
        />
        <Stat
          label="Back a week on"
          value={pctOf(d7.back, d7.of)}
          sub={d7.of ? `${num(d7.back)} of ${num(d7.of)}` : "no cohort has reached day 7"}
          muted
        />
        <Stat
          label="Back a month on"
          value={pctOf(d30.back, d30.of)}
          sub={d30.of ? `${num(d30.back)} of ${num(d30.of)}` : "no cohort has reached day 30"}
          muted
        />
        <Stat label="Sessions" value={num(sessions)} sub="reported by the phone" muted />
      </Stats>

      <div className={s.two}>
        <Daily title="Players each day" points={a.active} unit={["player", "players"]}>
          <p className={s.note}>
            Everyone who sent the game a request that UTC day, kept day by day. Days from before
            that record existed know only each player&rsquo;s joining day and last day, so they
            read low.
          </p>
        </Daily>
        <Daily title="New lords each day" points={a.registrations} unit={["joined", "joined"]} />
      </div>

      <Panel title="Who came back" flush>
        <div style={{ padding: "var(--s5) var(--s6)", borderBottom: "1px solid var(--hair)" }} className={s.note}>
          Players by the UTC day they joined, and how many were back exactly one, seven and thirty
          days later. Accounts deleted since stay in the cohort they joined, so leaving does not
          flatter the number. A dash is a day that has not come yet.
        </div>
        {a.retention.length === 0 ? (
          <EmptyState title={`Nobody joined in the last ${a.days} days`} />
        ) : (
          <TableWrap>
            <table className={s.cohorts}>
              <thead>
                <tr><th>joined</th><th>lords</th><th>day 1</th><th>day 7</th><th>day 30</th></tr>
              </thead>
              <tbody>
                {a.retention.map((c) => (
                  <tr key={c.day}>
                    <td className="u-mono">{c.day}</td>
                    <td>{num(c.size)}</td>
                    <Heat n={c.d1} size={c.size} />
                    <Heat n={c.d7} size={c.size} />
                    <Heat n={c.d30} size={c.size} />
                  </tr>
                ))}
              </tbody>
            </table>
          </TableWrap>
        )}
      </Panel>

      <DayByDay kpis={a.kpis ?? []} days={a.days} />

      <div className={s.two}>
        <Panel title="How long sessions last" flush>
          <Ranked
            rows={a.sessions.map((p) => ({ name: p.day, count: p.count }))}
            head="in the game" unit="sessions"
            empty={<EmptyState title="No session has been reported in this window"><span className="u-faint">The phone reports how long it stayed in front each time the game leaves the screen.</span></EmptyState>}
          />
        </Panel>
        <Panel title="Where lords are, by level" flush>
          <Ranked
            // Bands are tens from the server ("0-9", "10-19"); nobody is level 0.
            rows={a.level_bands.map((p) => ({ name: `level ${p.day.replace(/^0-/, "1-")}`, count: p.count }))}
            head="levels" unit="lords"
            empty={<EmptyState title="No lords yet" />}
          />
        </Panel>
      </div>

      <div className={s.two}>
        <Panel title="Screens opened" flush>
          <Ranked
            rows={a.screens}
            head="screen" unit="views"
            empty={<EmptyState title="No screen has been reported in this window"><span className="u-faint">A tab is its id; a page over the game is page: and its title.</span></EmptyState>}
          />
        </Panel>
        <Panel title="What the phone reported" flush>
          <Ranked
            rows={a.events}
            head="event" unit="events"
            empty={<EmptyState title="No event has been reported in this window"><span className="u-faint">Only the names the server lists are kept; anything else is dropped on arrival.</span></EmptyState>}
          />
        </Panel>
      </div>
    </div>
  );
}
