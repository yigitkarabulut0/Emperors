"use client";

import { Fragment, useState } from "react";
import Link from "next/link";
import { useMutate, useSlice } from "@/store/react";
import { Button, Field, Pill } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { atLeast } from "@/lib/ops";
import { localPrice, shortDate, usd } from "@/lib/format";
import type { GrantLine, Txn } from "./types";
import s from "./billing.module.css";

/** A row that spans the table and wraps: the table's cells are one line tall
 *  and never wrap, and its `.table tbody td` outranks a class here, so the
 *  jobs board sets its error rows the same way, inline. */
const FULL_ROW: React.CSSProperties = { whiteSpace: "normal", height: "auto", padding: "var(--s3) var(--s5) var(--s4)" };

const STATE_TONE: Record<string, "ok" | "bad" | "warn"> = { granted: "ok", refunded: "bad", revoked: "warn" };

/** What a purchase gave, in the phone's own words. */
function grantedText(t: Txn): string {
  const lines = Array.isArray(t.granted) ? (t.granted as GrantLine[]) : [];
  if (lines.length === 0) return t.state === "granted" ? "—" : "nothing: undone before it was delivered";
  return lines.map((l) => l.text).join(" · ");
}

/**
 * Purchases, newest first. A designer can take one back from its row: the
 * form sits under the row it acts on, and says what it will do before it does.
 * `onChanged` refetches whatever the page shows around the table.
 */
export function TxnTable({ rows, showPlayer = true, onChanged }: {
  rows: Txn[];
  showPlayer?: boolean;
  onChanged?: () => void;
}) {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const canTake = me ? atLeast(me.role, "designer") : false;
  const [open, setOpen] = useState<string | null>(null);
  const [state, setState] = useState<"refunded" | "revoked">("refunded");
  const [note, setNote] = useState("");

  const cols = showPlayer ? 8 : 7;

  async function takeBack(t: Txn) {
    const res = await mutate<{ outcome: string }>("billingTakeBack",
      { transaction_id: t.transaction_id, state, note },
      { key: `take:${t.transaction_id}`, success: "purchase taken back" });
    if (res.ok) {
      setOpen(null);
      setNote("");
      onChanged?.();
    }
  }

  return (
    <TableWrap>
      <Table>
        <thead>
          <tr>
            <th>bought (utc)</th>
            {showPlayer && <th>lord</th>}
            <th>product</th>
            <th>store</th>
            <th className={numCell}>price</th>
            <th>gave</th>
            <th>state</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((t) => (
            <Fragment key={t.id}>
              <tr>
                <td className="u-mono u-faint">{shortDate(t.purchased_at)}</td>
                {showPlayer && (
                  <td>
                    {t.deleted ? (
                      <span className="u-row">
                        <span className="u-faint">deleted</span>
                        <span className="u-mono u-faint" style={{ fontSize: "var(--t-micro)" }}>{t.player_id.slice(0, 8)}</span>
                      </span>
                    ) : (
                      <Link href={`/players/${t.player_id}`}>{t.username}</Link>
                    )}
                  </td>
                )}
                <td>
                  <div className={s.twoLine}>
                    <span>{t.product_name}</span>
                    <span className="u-mono u-faint" title={`${t.store_product_id}\ntransaction ${t.transaction_id}\noriginal ${t.original_transaction_id}`}>
                      {t.transaction_id}
                    </span>
                  </div>
                </td>
                <td>
                  {/* Sandbox is labelled in words as well as colour: it is never revenue. */}
                  {t.sandbox
                    ? <Pill tone="synthetic" dot hollow title="App Review, TestFlight or a test account: not revenue">SANDBOX</Pill>
                    : <span className="u-faint">{t.storefront || "—"}</span>}
                </td>
                <td className={numCell}>
                  <div className={s.twoLine} style={{ alignItems: "flex-end" }}>
                    <span>{usd(t.usd_cents)}</span>
                    <span className="u-faint" style={{ fontSize: "var(--t-micro)" }}>{localPrice(t.price_milli, t.currency)}</span>
                  </div>
                </td>
                <td className={s.gave} title={grantedText(t)}>{grantedText(t)}</td>
                <td>
                  <div className={s.twoLine}>
                    <Pill tone={STATE_TONE[t.state] ?? "warn"} dot hollow={t.state !== "granted"}>{t.state}</Pill>
                    {t.refunded_at && <span className="u-faint" style={{ fontSize: "var(--t-micro)" }}>{shortDate(t.refunded_at)}</span>}
                  </div>
                </td>
                <td style={{ textAlign: "right" }}>
                  {canTake && t.state === "granted" && !t.deleted && (
                    <Button size="sm" variant="quiet"
                      onClick={() => { setOpen(open === t.transaction_id ? null : t.transaction_id); setNote(""); }}>
                      {open === t.transaction_id ? "cancel" : "take back"}
                    </Button>
                  )}
                </td>
              </tr>
              {t.refund_note && (
                <tr>
                  <td colSpan={cols} style={FULL_ROW}>
                    <span className="u-micro">note</span> <span className="u-dim">{t.refund_note}</span>
                  </td>
                </tr>
              )}
              {open === t.transaction_id && (
                <tr>
                  <td colSpan={cols} style={{ ...FULL_ROW, background: "var(--ink-2)" }}>
                    <form
                      className={s.takeBack}
                      onSubmit={(e) => { e.preventDefault(); void takeBack(t); }}
                    >
                      <p className="u-faint" style={{ margin: 0 }}>
                        Takes back everything this purchase gave, exactly as Apple&rsquo;s refund would:
                        its diamonds (what has been spent becomes a debt, repaid first from what the lord
                        earns next), its tokens, cosmetics and lasting rights, a stipend&rsquo;s shares,
                        a Largesse&rsquo;s unopened letters, and its Royal Favour. The reason is kept on the
                        transaction and in the audit trail.
                      </p>
                      <div className={s.inline}>
                        <Field label="because">
                          <select id={`take-state-${t.id}`} value={state} onChange={(e) => setState(e.target.value as "refunded" | "revoked")}>
                            <option value="refunded">Apple refunded it; the notice never arrived</option>
                            <option value="revoked">Support takes it back (no money returned)</option>
                          </select>
                        </Field>
                        <div className={s.grow}>
                          <Field label="why">
                            <input id={`take-note-${t.id}`} value={note} onChange={(e) => setNote(e.target.value)}
                              placeholder="refund 2026-09-12 seen in App Store Connect" style={{ width: "100%" }} />
                          </Field>
                        </div>
                        <Button type="submit" variant="danger" disabled={!note.trim()}
                          busy={pending.has(`take:${t.transaction_id}`)}>
                          Take back {usd(t.usd_cents)}
                        </Button>
                      </div>
                    </form>
                  </td>
                </tr>
              )}
            </Fragment>
          ))}
        </tbody>
      </Table>
    </TableWrap>
  );
}
