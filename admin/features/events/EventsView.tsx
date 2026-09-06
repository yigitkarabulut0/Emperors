"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { bp, shortDate } from "@/lib/format";
import s from "./events.module.css";

type Bucket = { bucket: string; label: string; help: string; cap_bp: number };
type Boost = {
  id: number; bucket: string; amount_bp: number; starts_at: string; ends_at: string;
  note: string; created_by: string; live: boolean; revoked: boolean;
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

  async function start() {
    const res = await mutate("boostCreate", {
      bucket, amount_bp: amount, hours,
      note: (document.getElementById("boost-note") as HTMLInputElement)?.value ?? "",
    }, { key: "boost", success: `${spec?.label ?? bucket} ${bp(amount)} for ${hours}h` });
    if (res.ok) await load();
  }

  async function revoke(b: Boost) {
    if (!confirm(`End "${b.note || b.bucket}" now? Every player loses the bonus immediately.`)) return;
    const res = await mutate("boostRevoke", { id: b.id }, { key: "revoke:" + b.id, success: "event ended" });
    if (res.ok) await load();
  }

  return (
    <div className={s.page}>
      {canDesign && (
        <Panel title="Start a server-wide event">
          <div className={s.form}>
            <div className={s.inline}>
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
                label="for how long"
                hint={<span className={s.readout}>ends {new Date(Date.now() + hours * 3600_000).toISOString().slice(0, 16).replace("T", " ")}</span>}
              >
                <input type="number" value={hours} min={1} max={720} onChange={(e) => setHours(Number(e.target.value))} />
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
                <Field label="why" hint="Shown in the event list and the audit trail.">
                  <input id="boost-note" placeholder="weekend event" style={{ width: "100%" }} />
                </Field>
              </div>
              <Button variant="primary" busy={pending.has("boost")} disabled={overCap} onClick={start}>
                Start it
              </Button>
            </div>
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
                    {b.revoked ? <Pill tone="bad" dot hollow>ended early</Pill>
                      : b.live ? <Pill tone="ok" dot>live</Pill>
                      : new Date(b.starts_at) > new Date() ? <Pill tone="warn" dot hollow>scheduled</Pill>
                      : <Pill dot hollow>finished</Pill>}
                  </td>
                  <td>
                    {canDesign && b.live && (
                      <Button size="sm" variant="danger" busy={pending.has("revoke:" + b.id)} onClick={() => revoke(b)}>
                        end now
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
