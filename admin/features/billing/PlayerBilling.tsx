"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap } from "@/ui/Table";
import { atLeast } from "@/lib/ops";
import { count, num, shortDate, usd } from "@/lib/format";
import { TxnTable } from "./TxnTable";
import type { PlayerBilling as Billing, Txn } from "./types";
import s from "./billing.module.css";

/** The lasting rights a purchase can give, in the words the store uses. */
const RIGHTS: Record<string, string> = { steward: "The Steward", quartermaster: "The Quartermaster (more bag room)" };

const SUB_TONE: Record<string, "ok" | "warn" | "bad" | "neutral"> = {
  active: "ok", grace: "warn", billing_retry: "warn", expired: "neutral", revoked: "bad",
};

/**
 * What a lord's money left on them: Royal Favour, the patronage, lasting
 * rights, the stipend, refund debt, and every purchase. `stamp` changes after a
 * write elsewhere on the page; `onChanged` tells the page this panel wrote.
 */
export function PlayerBilling({ id, stamp, onChanged }: { id: string; stamp: number; onChanged: () => void }) {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const canForgive = me ? atLeast(me.role, "designer") : false;
  const [b, setB] = useState<Billing | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [forgiving, setForgiving] = useState(false);
  // A lasting right being given ("grant") or taken back ("revoke:<name>").
  const [right, setRight] = useState<string | null>(null);
  const [rightName, setRightName] = useState("");
  const [rightNote, setRightNote] = useState("");
  // Purchases older than the page's first fifty, fetched on request.
  const [older, setOlder] = useState<Txn[]>([]);
  const [olderBusy, setOlderBusy] = useState(false);

  const load = useCallback(async () => {
    const res = await query<Billing>("playerBilling", { id });
    if (res.ok) { setB(res.data); setOlder([]); setError(null); } else setError(res.message);
  }, [id]);

  useEffect(() => { void load(); }, [load, stamp]);

  const changed = () => { void load(); onChanged(); };

  async function forgive() {
    const res = await mutate("forgiveDebt", { player_id: id, note }, { key: "forgive", success: "debt forgiven" });
    if (res.ok) { setForgiving(false); setNote(""); changed(); }
  }

  async function changeRight(grant: boolean, name: string) {
    const res = await mutate("entitlement", { player_id: id, entitlement: name, grant, note: rightNote },
      { key: "entitlement", success: grant ? `${RIGHTS[name] ?? name} given` : `${RIGHTS[name] ?? name} taken back` });
    if (res.ok) { setRight(null); setRightName(""); setRightNote(""); changed(); }
  }

  async function loadOlder(before: number) {
    setOlderBusy(true);
    const res = await query<{ transactions: Txn[] }>("billingTransactions", { player: id, before, limit: 50 });
    if (res.ok) setOlder((prev) => [...prev, ...(res.data.transactions ?? [])]);
    setOlderBusy(false);
  }

  if (error) {
    return <Panel title="Purchases"><EmptyState title="Could not load this lord's purchases"><span className="u-faint">{error}</span></EmptyState></Panel>;
  }
  if (!b) return <Panel title="Purchases"><Skeleton h={120} /></Panel>;

  const favourShare = b.vip_next_at > 0 ? Math.min(1, b.vip_points / b.vip_next_at) : 1;
  const rows = [...b.transactions, ...older];
  const bought = b.purchases + b.sandbox_purchases;

  return (
    <Panel
      title="Purchases"
      flush
      actions={
        <span className="u-row">
          {b.flagged && <Pill tone="bad" dot title="Refunds often: see the billing desk">{count(b.recent_refunds, "refund", "refunds")} lately</Pill>}
          {b.diamond_debt > 0 && <Pill tone="bad" dot>owes {num(b.diamond_debt)}</Pill>}
        </span>
      }
    >
      <div className={s.two} style={{ padding: "var(--s6)" }}>
        <dl className={s.facts}>
          <dt>paid</dt>
          <dd>{usd(b.spent_cents)} <span className="u-faint">over {count(b.purchases, "purchase", "purchases")}{b.sandbox_purchases ? ` · ${num(b.sandbox_purchases)} in sandbox` : ""}</span></dd>
          <dt>royal favour</dt>
          <dd>
            {b.vip_level > 0 ? `level ${b.vip_level}` : "none yet"}{" "}
            <span className="u-faint">{usd(b.vip_points)}{b.vip_next_at ? ` of ${usd(b.vip_next_at)} for the next` : " · the top"}</span>
            <span className={s.track}><span className={s.fill} style={{ width: `${favourShare * 100}%` }} /></span>
          </dd>
          <dt>patronage</dt>
          <dd>{b.patron_until ? <>until {shortDate(b.patron_until)}</> : <span className="u-faint">no</span>}</dd>
          <dt>stipend</dt>
          <dd>
            {b.stipend_until
              ? <>runs to {b.stipend_until} <span className="u-faint">· last claimed {b.stipend_claimed || "never"}</span></>
              : <span className="u-faint">no</span>}
          </dd>
        </dl>
        <dl className={s.facts}>
          <dt>steward</dt>
          <dd>{b.steward ? <Pill tone="gold">owned</Pill> : <span className="u-faint">no</span>}</dd>
          <dt>extra bag</dt>
          <dd>{b.bag_bonus ? `+${num(b.bag_bonus)} slots` : <span className="u-faint">none</span>}</dd>
          <dt>diamonds</dt>
          <dd>{num(b.diamonds)}{b.diamond_debt > 0 && <span style={{ color: "var(--down)" }}> · owes {num(b.diamond_debt)}</span>}</dd>
          <dt>bought</dt>
          <dd>
            {b.bought.length === 0 ? <span className="u-faint">nothing</span>
              : b.bought.map((x) => `${x.name} ×${x.count}`).join(" · ")}
          </dd>
        </dl>
      </div>

      {b.diamond_debt > 0 && canForgive && (
        <div style={{ padding: "0 var(--s6) var(--s6)" }}>
          {!forgiving ? (
            <Button size="sm" variant="ghost" onClick={() => setForgiving(true)}>forgive the debt</Button>
          ) : (
            <form className={s.takeBack} onSubmit={(e) => { e.preventDefault(); void forgive(); }}>
              <p className="u-faint" style={{ margin: 0 }}>
                Clears the {num(b.diamond_debt)} diamonds this lord owes from a refund. Nothing reaches
                their purse; the ledger records the whole debt as forgiven, and the reason goes in the
                audit trail.
              </p>
              <div className={s.inline}>
                <div className={s.grow}>
                  <Field label="why">
                    <input id="forgive-note" value={note} onChange={(e) => setNote(e.target.value)}
                      placeholder="refunded by mistake; the buyer bought again" style={{ width: "100%" }} />
                  </Field>
                </div>
                <Button type="submit" variant="primary" disabled={!note.trim()} busy={pending.has("forgive")}>
                  Forgive {num(b.diamond_debt)}
                </Button>
                <Button variant="quiet" onClick={() => { setForgiving(false); setNote(""); }}>cancel</Button>
              </div>
            </form>
          )}
        </div>
      )}

      {canForgive && (() => {
        const held = new Set(b.entitlements.map((e) => e.name));
        const giveable = Object.keys(RIGHTS).filter((r) => !held.has(r));
        const revoking = right?.startsWith("revoke:") ? right.slice(7) : null;
        if (right === null) {
          return giveable.length > 0 && (
            <div style={{ padding: "0 var(--s6) var(--s6)" }}>
              <Button size="sm" variant="ghost" onClick={() => { setRight("grant"); setRightName(giveable[0]); }}>give a lasting right</Button>
            </div>
          );
        }
        return (
          <div style={{ padding: "0 var(--s6) var(--s6)" }}>
            <form className={s.takeBack} onSubmit={(e) => { e.preventDefault(); void changeRight(!revoking, revoking ?? rightName); }}>
              <p className="u-faint" style={{ margin: 0 }}>
                {revoking
                  ? <>Takes back {RIGHTS[revoking] ?? revoking}, which the panel gave. A right a purchase gave is taken back with its purchase, above.</>
                  : <>Gives what the purchase would, for good, without a purchase: support&apos;s answer when a lord lost
                    what they paid for and no purchase record can mend it. It shows as given by you, and the reason goes
                    in the audit trail.</>}
              </p>
              <div className={s.inline}>
                {!revoking && (
                  <Field label="right">
                    <select id="right-name" value={rightName} onChange={(e) => setRightName(e.target.value)}>
                      {giveable.map((r) => <option key={r} value={r}>{RIGHTS[r]}</option>)}
                    </select>
                  </Field>
                )}
                <div className={s.grow}>
                  <Field label="why">
                    <input id="right-note" value={rightNote} onChange={(e) => setRightNote(e.target.value)}
                      placeholder={revoking ? "given to the wrong lord" : "bought on a lost account; receipt seen"} style={{ width: "100%" }} />
                  </Field>
                </div>
                <Button type="submit" variant={revoking ? "danger" : "primary"} disabled={!rightNote.trim()} busy={pending.has("entitlement")}>
                  {revoking ? "Take it back" : "Give it"}
                </Button>
                <Button variant="quiet" onClick={() => { setRight(null); setRightNote(""); }}>cancel</Button>
              </div>
            </form>
          </div>
        );
      })()}

      {(b.entitlements.length > 0 || b.subscriptions.length > 0) && (
        <TableWrap>
          <Table>
            <thead><tr><th>lasting right</th><th>state</th><th>since / until</th><th>transaction</th><th /></tr></thead>
            <tbody>
              {b.entitlements.map((e) => {
                const byHand = e.transaction_id.startsWith("admin:");
                return (
                  <tr key={e.name}>
                    <td>{RIGHTS[e.name] ?? e.name}</td>
                    <td><Pill tone="ok" dot>{byHand ? "given" : "owned"}</Pill></td>
                    <td className="u-mono u-faint">{shortDate(e.granted_at)}</td>
                    <td className="u-mono u-faint">{byHand ? `by ${e.transaction_id.slice(6)}` : e.transaction_id}</td>
                    <td style={{ textAlign: "right" }}>
                      {byHand && canForgive && right === null && (
                        <Button size="sm" variant="quiet" onClick={() => setRight(`revoke:${e.name}`)}>take back</Button>
                      )}
                    </td>
                  </tr>
                );
              })}
              {b.subscriptions.map((x) => (
                <tr key={x.original_transaction_id}>
                  <td>
                    Crown Patronage{" "}
                    {x.environment !== "Production" && <Pill tone="synthetic" dot hollow>SANDBOX</Pill>}
                  </td>
                  <td>
                    <span className="u-row">
                      <Pill tone={SUB_TONE[x.status] ?? "neutral"} dot hollow={x.status !== "active"}>{x.status.replace("_", " ")}</Pill>
                      <span className="u-faint">{x.auto_renew ? "renews" : "will not renew"}</span>
                    </span>
                  </td>
                  <td className="u-mono u-faint">{shortDate(x.expires_at)}</td>
                  <td className="u-mono u-faint">{x.original_transaction_id}</td>
                  <td />
                </tr>
              ))}
            </tbody>
          </Table>
        </TableWrap>
      )}

      {b.offers.length > 0 && (
        <TableWrap>
          <Table>
            <thead><tr><th>offer shown</th><th>fired</th><th>ends</th><th>seen</th></tr></thead>
            <tbody>
              {b.offers.map((o) => (
                <tr key={o.product_id}>
                  <td>{o.name}</td>
                  <td className="u-mono u-faint">{shortDate(o.fired_at)}</td>
                  <td className="u-mono u-faint">{shortDate(o.expires_at)}</td>
                  <td className="u-faint">{o.seen_at ? shortDate(o.seen_at) : "not yet"}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableWrap>
      )}

      {rows.length === 0 ? (
        <EmptyState title="This lord has bought nothing" />
      ) : (
        <>
          <TxnTable rows={rows} showPlayer={false} onChanged={changed} />
          {bought > rows.length && (
            <div className={s.more}>
              <Button size="sm" variant="quiet" busy={olderBusy} onClick={() => void loadOlder(rows[rows.length - 1].id)}>
                older · {num(bought - rows.length)} more
              </Button>
            </div>
          )}
        </>
      )}
    </Panel>
  );
}
