"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { bp, parseUTC, shortDate } from "@/lib/format";
import s from "./events.module.css";

type Bucket = { bucket: string; label: string; help: string; cap_bp: number };
type Boost = {
  id: number; bucket: string; amount_bp: number; starts_at: string; ends_at: string;
  note: string; created_by: string; live: boolean; scheduled: boolean; revoked: boolean;
};

export function EventsView() {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [boosts, setBoosts] = useState<Boost[] | null>(null);
  const [buckets, setBuckets] = useState<Bucket[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [bucket, setBucket] = useState("collect_income_bp");
  const [amount, setAmount] = useState(5000);
  const [hours, setHours] = useState(48);
  const [startsIn, setStartsIn] = useState(0);

  const load = useCallback(async () => {
    const res = await query<{ boosts: Boost[]; buckets: Bucket[] }>("boosts");
    if (res.ok) {
      setBoosts(res.data.boosts ?? []);
      setBuckets(res.data.buckets ?? []);
      if (res.data.buckets?.length && !res.data.buckets.some((b) => b.bucket === bucket)) {
        setBucket(res.data.buckets[0].bucket);
      }
      setError(null);
    } else setError(res.message);
  }, [bucket]);

  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const canDesign = me ? atLeast(me.role, "designer") : false;
  const spec = buckets.find((b) => b.bucket === bucket);
  const overCap = spec ? Math.abs(amount) > spec.cap_bp : false;
  // Two live events on the same bucket stack into one total that shares one cap,
  // so an operator adding a second needs to know before they click.
  const clash = (boosts ?? []).filter((b) => b.live && b.bucket === bucket);
  const startAt = Date.now() + startsIn * 3600_000;
  const stamp = (ms: number) => new Date(ms).toISOString().slice(0, 16).replace("T", " ");

  async function start() {
    const res = await mutate("boostCreate", {
      bucket, amount_bp: amount, hours, starts_in_hours: startsIn,
      note: (document.getElementById("boost-note") as HTMLInputElement)?.value ?? "",
    }, {
      key: "boost",
      success: startsIn > 0
        ? `${spec?.label ?? bucket} ${bp(amount)} for ${hours}h, from ${stamp(startAt)} utc`
        : `${spec?.label ?? bucket} ${bp(amount)} for ${hours}h`,
    });
    if (res.ok) await load();
  }

  async function revoke(b: Boost) {
    const ask = b.live
      ? `End "${b.note || b.bucket}" now? Every player loses the bonus immediately.`
      : `Cancel "${b.note || b.bucket}"? It will not start, and the game stops announcing it.`;
    if (!confirm(ask)) return;
    const res = await mutate("boostRevoke", { id: b.id }, { key: "revoke:" + b.id, success: b.live ? "event ended" : "event cancelled" });
    if (res.ok) await load();
  }

  return (
    <div className={s.page}>
      {canDesign && (
        <Panel title="Start a server-wide event">
          <div className={s.form}>
            <div className={s.fields}>
              <Field label="what">
                <select value={bucket} onChange={(e) => setBucket(e.target.value)} style={{ minWidth: 190 }}>
                  {buckets.map((b) => (
                    <option key={b.bucket} value={b.bucket}>{b.label}</option>
                  ))}
                </select>
              </Field>
              <Field
                label="how much"
                hint={<span className={s.readout}>{bp(amount)}</span>}
                error={overCap && spec ? `above the cap of ${bp(spec.cap_bp)} — the server will refuse it` : null}
              >
                <input type="number" step={500} value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
              </Field>
              <Field
                label="starts in (hours)"
                hint={<span className={s.readout}>{startsIn > 0 ? `${stamp(startAt)} utc · announced a day ahead` : "now"}</span>}
              >
                <input id="boost-starts" type="number" value={startsIn} min={0} max={720}
                  onChange={(e) => setStartsIn(Math.max(0, Math.trunc(Number(e.target.value) || 0)))} />
              </Field>
              <Field
                label="for how long"
                hint={<span className={s.readout}>ends {stamp(startAt + hours * 3600_000)} utc</span>}
              >
                <input id="boost-hours" type="number" value={hours} min={1} max={720} onChange={(e) => setHours(Number(e.target.value))} />
              </Field>
            </div>
            {spec && <p className={s.help}>{spec.help} Capped at {bp(spec.cap_bp)}.</p>}
            {clash.length > 0 && (
              <p className={s.warn}>
                {clash.length} event{clash.length > 1 ? "s are" : " is"} already running on this
                bucket. They add together and share one cap, so the total is what players feel.
              </p>
            )}
            <div className={s.inline}>
              <div className={s.note}>
                <Field label="why">
                  <input id="boost-note" placeholder="weekend event" style={{ width: "100%" }} />
                </Field>
              </div>
              <Button variant="primary" busy={pending.has("boost")} disabled={overCap} onClick={start}>
                {startsIn > 0 ? "Schedule it" : "Start it"}
              </Button>
            </div>
            <p className={s.help}>The why is shown in the event list and the audit trail.</p>
          </div>
        </Panel>
      )}

      <Panel title="Events" flush>
        {error ? (
          <EmptyState title="Could not load events"><span className="u-faint">{error}</span></EmptyState>
        ) : !boosts ? (
          <div style={{ padding: "var(--s6)" }}><Skeleton h={120} /></div>
        ) : boosts.length === 0 ? (
          <EmptyState title="No event has ever run">
            <span className="u-faint">Start one above and every player feels it on their next action.</span>
          </EmptyState>
        ) : (
          <table className={s.table}>
            <thead>
              <tr>
                <th>what</th><th className={s.num}>bonus</th><th>window</th>
                <th>by</th><th>why</th><th>state</th><th />
              </tr>
            </thead>
            <tbody>
              {boosts.map((b) => (
                <tr key={b.id}>
                  <td>{buckets.find((x) => x.bucket === b.bucket)?.label ?? b.bucket}</td>
                  <td className={s.num} style={{ color: "var(--gold-3)" }}>{bp(b.amount_bp)}</td>
                  <td className="u-faint">{shortDate(b.starts_at)} → {shortDate(b.ends_at)}</td>
                  <td className="u-dim">{b.created_by}</td>
                  <td className="u-faint">{b.note || "—"}</td>
                  <td>
                    {b.revoked ? <Pill tone="bad" dot hollow>{(parseUTC(b.starts_at)?.getTime() ?? 0) > Date.now() ? "cancelled" : "ended early"}</Pill>
                      : b.live ? <Pill tone="ok" dot>live</Pill>
                      : b.scheduled || (parseUTC(b.starts_at)?.getTime() ?? 0) > Date.now() ? <Pill tone="warn" dot hollow>scheduled</Pill>
                      : <Pill dot hollow>finished</Pill>}
                  </td>
                  <td>
                    {canDesign && (b.live || b.scheduled) && (
                      <Button size="sm" variant="danger" busy={pending.has("revoke:" + b.id)} onClick={() => revoke(b)}>
                        {b.live ? "end now" : "cancel"}
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
    </div>
  );
}
