"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { num, usd } from "@/lib/format";
import s from "./experiments.module.css";

type Arm = {
  id: string; product: string; weight: number; price_cents: number;
  exposed: number; converted: number; revenue_cents: number;
  conversion_bp: number; per_lord_centicents: number; z: number; significant: boolean;
};
type Experiment = { id: string; active: boolean; note: string; arms: Arm[] };

/** Two-line cells: the table's rows are one line high by default. */
const ROW: React.CSSProperties = { height: "auto", paddingBlock: "var(--s3)" };

/** Below this many lords shown on either side, no arm is called better. */
const ENOUGH = 100;

const pct = (bp: number) => `${(bp / 100).toFixed(bp > 0 && bp < 1000 ? 2 : 1)}%`;
/** Hundredths of a cent as dollars, with the digits a small figure needs. */
const perLord = (cc: number) => `$${(cc / 10000).toFixed(cc > 0 && cc < 10000 ? 4 : 2)}`;

function share(a: Arm, arms: Arm[]): string {
  const total = arms.reduce((t, x) => t + Math.max(0, x.weight), 0);
  return total ? `${Math.round((a.weight / total) * 100)}%` : "—";
}

/** What the figures say so far, in a sentence an operator can act on. */
function verdict(e: Experiment): React.ReactNode {
  const [control, ...rest] = e.arms;
  if (!control) return null;
  const shown = e.arms.reduce((t, a) => t + a.exposed, 0);
  if (shown === 0) {
    return e.active
      ? "Running, and nobody has been shown an arm yet: lords are counted the first time their arm's offer opens."
      : "Off: every lord is shown the control. Nothing has been counted.";
  }
  const thin = e.arms.filter((a) => a.exposed < ENOUGH);
  if (thin.length > 0) {
    return <>Too early to call: {thin.map((a) => a.id).join(" and ")} {thin.length === 1 ? "has" : "have"} been shown to fewer than {ENOUGH} lords.</>;
  }
  const best = [...e.arms].sort((a, b) => b.per_lord_centicents - a.per_lord_centicents)[0];
  const called = rest.filter((a) => a.significant);
  return (
    <>
      <b>{best.id}</b> earns the most per lord shown ({perLord(best.per_lord_centicents)}).{" "}
      {called.length === 0
        ? "No arm converts differently from the control at 95% yet."
        : called.map((a) => `${a.id} converts ${a.z > 0 ? "better" : "worse"} than the control (z ${a.z.toFixed(2)})`).join("; ") + "."}{" "}
      A dearer arm can convert less and still earn more: weigh both columns.
    </>
  );
}

function ExperimentPanel({ e, busy, reload }: { e: Experiment; busy: boolean; reload: () => void }) {
  return (
    <Panel
      title={<span className={s.head}><span className="u-mono">{e.id}</span>
        <Pill tone={e.active ? "ok" : "neutral"} dot hollow={!e.active}>{e.active ? "running" : "off"}</Pill></span>}
      actions={<Button size="sm" variant="quiet" busy={busy} onClick={reload}>refresh</Button>}
      flush
    >
      {e.note && <div className={s.verdict}><span className={s.note}>{e.note}</span></div>}
      <TableWrap>
        <Table>
          <thead>
            <tr>
              <th>arm</th><th>sells</th><th className={numCell}>share</th><th className={numCell}>shown</th>
              <th className={numCell}>bought</th><th className={numCell}>converts</th><th className={numCell}>revenue</th>
              <th className={numCell}>per lord shown</th><th>against the control</th>
            </tr>
          </thead>
          <tbody>
            {e.arms.map((a, i) => (
              <tr key={a.id}>
                <td style={ROW}>
                  <div className={s.twoLine}>
                    <span className="u-mono">{a.id}</span>
                    <span className="u-faint">{i === 0 ? "the control" : "tried against it"}</span>
                  </div>
                </td>
                <td style={ROW}>
                  <div className={s.twoLine}>
                    <span className="u-mono">{a.product}</span>
                    <span className="u-faint">{usd(a.price_cents)}</span>
                  </div>
                </td>
                <td className={numCell} style={ROW}>{share(a, e.arms)}</td>
                <td className={numCell} style={ROW}>{num(a.exposed)}</td>
                <td className={numCell} style={ROW}>{num(a.converted)}</td>
                <td className={numCell} style={ROW}>{a.exposed ? pct(a.conversion_bp) : "—"}</td>
                <td className={numCell} style={ROW}>{usd(a.revenue_cents)}</td>
                <td className={numCell} style={ROW}>{a.exposed ? perLord(a.per_lord_centicents) : "—"}</td>
                <td style={ROW}>
                  {i === 0 ? <span className="u-faint">—</span>
                    : a.exposed < ENOUGH || e.arms[0].exposed < ENOUGH
                      ? <span className="u-faint">too few lords</span>
                      : <Pill tone={a.significant ? (a.z > 0 ? "ok" : "bad") : "neutral"} dot hollow={!a.significant}
                          title="Two-proportion z test on conversion; 1.96 is 95% two-sided.">
                          z {a.z.toFixed(2)}{a.significant ? (a.z > 0 ? " · better" : " · worse") : " · no difference yet"}
                        </Pill>}
                </td>
              </tr>
            ))}
          </tbody>
        </Table>
      </TableWrap>
      <div className={s.verdict}>{verdict(e)}</div>
    </Panel>
  );
}

export function ExperimentsView() {
  const [list, setList] = useState<Experiment[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    const res = await query<{ experiments: Experiment[] }>("experiments");
    if (res.ok) { setList(res.data.experiments ?? []); setError(null); } else setError(res.message);
    setBusy(false);
  }, []);

  useEffect(() => { void load(); }, [load]);

  return (
    <div className={s.page}>
      <p className={s.explain}>
        Each test puts every lord in one arm for good (a keyed hash of the lord and the test, never stored) and shows
        them that arm&apos;s offer, once; a lord is counted the first time it opens. A purchase counts when that lord
        buys the arm&apos;s product afterwards, in Production. Tests live in the balance
        (<span className="u-mono">commerce.experiments</span>): switch one on or off there and publish. A lord who has
        had one arm is never shown the other.
      </p>
      {error && !list ? (
        <EmptyState title="Could not load the tests"><span className="u-faint">{error}</span></EmptyState>
      ) : !list ? (
        <Skeleton h={220} />
      ) : list.length === 0 ? (
        <EmptyState title="No test in the live balance" />
      ) : (
        list.map((e) => <ExperimentPanel key={e.id} e={e} busy={busy} reload={() => void load()} />)
      )}
    </div>
  );
}
