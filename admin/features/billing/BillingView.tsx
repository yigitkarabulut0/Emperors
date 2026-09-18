"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { query, useMutate, useNowTick, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { Columns } from "@/ui/Columns";
import { atLeast } from "@/lib/ops";
import { ago, count, num, parseUTC, pctOf, shortDate, usd } from "@/lib/format";
import { TxnTable } from "./TxnTable";
import type { Notice, Summary, Txn } from "./types";
import s from "./billing.module.css";

const PAGE = 50;
const WINDOWS = [7, 30, 90];

/* ---------------------------------------------------------------- takings --- */

function Takings({ days }: { days: number }) {
  const [sum, setSum] = useState<Summary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [table, setTable] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    const res = await query<Summary>("billingSummary", { days });
    if (res.ok) { setSum(res.data); setError(null); } else setError(res.message);
    setBusy(false);
  }, [days]);

  useEffect(() => { void load(); }, [load]);

  if (error && !sum) {
    return <EmptyState title="Could not load the takings"><span className="u-faint">{error}</span></EmptyState>;
  }
  if (!sum) return <Skeleton h={220} />;

  const noticeTone = sum.abandoned_notifications > 0 ? "bad" : sum.pending_notifications > 0 ? "warn" : "ok";
  return (
    <div className={`${s.page} ${busy ? s.refetching : ""}`}>
      <Stats>
        <Stat label="net takings" value={usd(sum.net_cents)}
          sub={`${usd(sum.gross_cents)} in · ${usd(sum.refund_cents)} refunded`}
          title="Production only. Apple's cut is not taken off: this is what buyers paid, less what Apple refunded." />
        <Stat label="purchases" value={num(sum.purchases)} sub={count(sum.payers, "paying lord", "paying lords")} />
        <Stat label="per paying lord" value={usd(sum.arppu_cents)} sub="net ÷ payers (ARPPU)" />
        <Stat label="lords who paid" value={`${(sum.conversion_bp / 100).toFixed(sum.conversion_bp < 1000 ? 2 : 1)}%`}
          sub={`${num(sum.payers)} of ${count(sum.active_lords, "lord who played", "lords who played")}`}
          title="Payers in Production over every lord who played in the window." />
        <Stat label="per lord per day" value={`$${(sum.arpdau_centicents / 10000).toFixed(4)}`}
          sub="net ÷ days played (ARPDAU)"
          title="Net takings over lord-days: each day each lord played counts once." />
        <Stat label="refunds" value={num(sum.refunds)}
          sub={`${pctOf(sum.refunds, sum.purchases)} of purchases${sum.revoked ? ` · ${num(sum.revoked)} taken back` : ""}`} />
        <Stat label="sandbox" value={num(sum.sandbox_purchases)} muted
          sub={`${usd(sum.sandbox_cents)} · never revenue`}
          title="App Review, TestFlight and test accounts. Listed, never counted." />
        <Stat label="app store notices"
          value={<Pill tone={noticeTone} dot>{sum.abandoned_notifications ? `${num(sum.abandoned_notifications)} abandoned` : sum.pending_notifications ? `${num(sum.pending_notifications)} pending` : "all acted on"}</Pill>}
          sub="refunds and renewals Apple sent" />
      </Stats>

      <Panel
        title={`Takings by day · last ${sum.days} days (utc)`}
        flush={table}
        actions={<Button size="sm" variant="quiet" onClick={() => setTable(!table)}>{table ? "chart" : "table"}</Button>}
      >
        {table ? (
          <TableWrap>
            <Table>
              <thead>
                <tr><th>day (utc)</th><th className={numCell}>purchases</th><th className={numCell}>in</th><th className={numCell}>refunded</th><th className={numCell}>net</th></tr>
              </thead>
              <tbody>
                {[...sum.daily].reverse().map((d) => (
                  <tr key={d.day}>
                    <td className="u-mono u-dim">{d.day}</td>
                    <td className={numCell}>{num(d.purchases)}</td>
                    <td className={numCell}>{usd(d.gross_cents)}</td>
                    <td className={numCell} style={{ color: d.refund_cents ? "var(--down)" : "var(--text-3)" }}>{usd(d.refund_cents)}</td>
                    <td className={numCell}>{usd(d.gross_cents - d.refund_cents)}</td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableWrap>
        ) : sum.gross_cents === 0 ? (
          <EmptyState title="Nothing sold in Production yet">
            <span className="u-faint">Sandbox purchases are listed below and never counted here.</span>
          </EmptyState>
        ) : (
          <Columns points={sum.daily.map((d) => ({ day: d.day, count: d.gross_cents }))} unit={["taken", "taken"]} format={usd} />
        )}
      </Panel>

      <div className={s.two}>
        <Panel title="By product" flush>
          {sum.products.length === 0 ? (
            <EmptyState title="No product sold in Production in this window" />
          ) : (
            <TableWrap>
              <Table>
                <thead>
                  <tr><th>product</th><th className={numCell}>sold</th><th className={numCell}>lords</th><th className={numCell}>in</th><th className={numCell}>refunded</th></tr>
                </thead>
                <tbody>
                  {sum.products.map((p) => (
                    <tr key={p.product_id}>
                      <td>
                        <div className={s.twoLine}>
                          <span>{p.name}</span>
                          <span className="u-mono u-faint">{p.product_id}</span>
                        </div>
                      </td>
                      <td className={numCell}>{num(p.purchases)}</td>
                      <td className={numCell}>{num(p.buyers)}</td>
                      <td className={numCell}>{usd(p.gross_cents)}</td>
                      <td className={numCell} style={{ color: p.refunds ? "var(--down)" : "var(--text-3)" }}>
                        {num(p.refunds)} <span className="u-faint">{p.refunds ? pctOf(p.refunds, p.purchases) : ""}</span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </TableWrap>
          )}
        </Panel>

        <Panel title={`Refunding often · ${sum.flag_refunds}+ in ${sum.flag_days} days`} flush>
          {sum.flagged.length === 0 ? (
            <EmptyState title="Nobody refunds often">
              <span className="u-faint">A lord appears here after {sum.flag_refunds} refunds or take-backs within {sum.flag_days} days.</span>
            </EmptyState>
          ) : (
            <TableWrap>
              <Table>
                <thead>
                  <tr><th>lord</th><th className={numCell}>refunds</th><th className={numCell}>refunded</th><th>last</th></tr>
                </thead>
                <tbody>
                  {sum.flagged.map((f) => (
                    <tr key={f.player_id}>
                      <td>{f.deleted ? <span className="u-faint">deleted · {f.player_id.slice(0, 8)}</span> : <Link href={`/players/${f.player_id}`}>{f.username}</Link>}</td>
                      <td className={numCell} style={{ color: "var(--down)" }}>{num(f.refunds)}</td>
                      <td className={numCell}>{usd(f.refund_cents)}</td>
                      <td className="u-mono u-faint">{shortDate(f.last_refund)}</td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </TableWrap>
          )}
        </Panel>
      </div>

      {sum.herald && <Herald h={sum.herald} />}
    </div>
  );
}

/* ------------------------------------------------------------- the herald --- */

/** Herald's Tidings: the rewarded advert, over the same window as the takings.
 *
 * What is NOT here is what the adverts earned. AdMob reports that, this server
 * never sees it, and a figure invented here would be invented money. What the
 * desk can say is what the herald cost in diamonds, and how many taps actually
 * came back -- a fill far below the usual is the SDK not filling, lords closing
 * the advert, or this server unreachable when Google called. */
function Herald({ h }: { h: NonNullable<Summary["herald"]> }) {
  const fill = h.fill_bp / 100;
  const tone = fill >= 70 ? "ok" : fill >= 40 ? "warn" : "bad";
  // h.days, not the takings' window: a paid watch is swept after 90 days, and a
  // year of takings beside 90 days of adverts would read as adverts stopping.
  return (
    <Panel title={`Herald's Tidings · last ${h.days} days`}>
      <Stats>
        <Stat label="adverts watched" value={num(h.paid)}
          sub={`${num(h.started)} started · ${count(h.lords, "lord", "lords")}`}
          title="A tap is a ticket; a watch counts once Google's signed callback has paid it." />
        <Stat label="came back"
          value={<Pill tone={tone} dot>{fill.toFixed(fill < 10 ? 1 : 0)}%</Pill>}
          sub="paid ÷ started"
          title="Low means the SDK did not fill, lords closed the advert early, or this server was unreachable when Google called." />
        <Stat label="diamonds paid" value={num(h.diamonds)}
          sub={h.paid ? `${(h.diamonds / h.paid).toFixed(1)} an advert` : "none yet"} />
        <Stat label="earned" value={<span className="u-faint">AdMob</span>} muted
          sub="this server never sees it"
          title="What the adverts paid is AdMob's own report. Nothing here estimates it." />
      </Stats>
    </Panel>
  );
}

/* ----------------------------------------------------------- transactions --- */

function Transactions() {
  const [env, setEnv] = useState("");
  const [state, setState] = useState("");
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [rows, setRows] = useState<Txn[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [more, setMore] = useState(false);

  const load = useCallback(async (before?: number) => {
    setBusy(true);
    const res = await query<{ transactions: Txn[] }>("billingTransactions",
      { env, state, q: applied, before, limit: PAGE });
    if (res.ok) {
      const got = res.data.transactions ?? [];
      setRows((prev) => (before && prev ? [...prev, ...got] : got));
      setMore(got.length === PAGE);
      setError(null);
    } else setError(res.message);
    setBusy(false);
  }, [env, state, applied]);

  useEffect(() => { void load(); }, [load]);

  return (
    <Panel
      title="Purchases"
      flush
      actions={
        <form className={s.filters} onSubmit={(e) => { e.preventDefault(); setApplied(search.trim()); }}>
          <select id="billing-env" aria-label="store" value={env} onChange={(e) => setEnv(e.target.value)}>
            <option value="">every store</option>
            <option value="Production">Production</option>
            <option value="Sandbox">Sandbox</option>
          </select>
          <select id="billing-state" aria-label="state" value={state} onChange={(e) => setState(e.target.value)}>
            <option value="">every state</option>
            <option value="granted">granted</option>
            <option value="refunded">refunded</option>
            <option value="revoked">taken back</option>
          </select>
          <input id="billing-search" aria-label="transaction id" value={search} onChange={(e) => setSearch(e.target.value)}
            placeholder="transaction id" style={{ width: 170 }} />
          <Button size="sm" variant="quiet" type="submit" busy={busy}>find</Button>
        </form>
      }
    >
      {error && !rows ? (
        <EmptyState title="Could not load the purchases"><span className="u-faint">{error}</span></EmptyState>
      ) : !rows ? (
        <div style={{ padding: "var(--s6)" }}><Skeleton h={160} /></div>
      ) : rows.length === 0 ? (
        <EmptyState title={applied || env || state ? "No purchase matches" : "Nothing has been bought yet"}>
          <span className="u-faint">Every purchase the App Store signs lands here once, the moment the phone or a notification delivers it.</span>
        </EmptyState>
      ) : (
        <>
          <TxnTable rows={rows} onChanged={() => void load()} />
          {more && (
            <div className={s.more}>
              <Button size="sm" variant="quiet" busy={busy} onClick={() => void load(rows[rows.length - 1].id)}>older</Button>
            </div>
          )}
        </>
      )}
    </Panel>
  );
}

/* ---------------------------------------------------------- notifications --- */

const NOTICE_TONE = { done: "ok", pending: "warn", abandoned: "bad" } as const;

function Notifications() {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const now = useNowTick(15_000);
  const canRetry = me ? atLeast(me.role, "moderator") : false;
  const [openOnly, setOpenOnly] = useState(false);
  const [rows, setRows] = useState<Notice[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    const res = await query<{ notifications: Notice[] }>("billingNotifications", { open: openOnly ? "1" : undefined, limit: 100 });
    if (res.ok) { setRows(res.data.notifications ?? []); setError(null); } else setError(res.message);
    setBusy(false);
  }, [openOnly]);

  useEffect(() => { void load(); }, [load]);

  async function retry(n: Notice) {
    const res = await mutate<{ outcome: string }>("billingRetry", { id: n.id }, { key: `retry:${n.id}`, success: "notification acted on" });
    if (res.ok) void load();
  }

  const when = (stamp: string | null) => {
    const d = parseUTC(stamp);
    return d ? <span title={`${stamp} UTC`}>{ago((now - d.getTime()) / 1000)}</span> : <span className="u-faint">—</span>;
  };

  return (
    <Panel
      title="App Store notifications"
      flush
      actions={
        <span className="u-row">
          <label className="u-row u-faint" htmlFor="billing-open-only">
            <input id="billing-open-only" type="checkbox" checked={openOnly} onChange={(e) => setOpenOnly(e.target.checked)} />
            only unfinished
          </label>
          <Button size="sm" variant="quiet" busy={busy} onClick={() => void load()}>refresh</Button>
        </span>
      }
    >
      <p className={s.explain}>
        Apple tells the server about renewals, lapses and refunds. Each notice is stored before it
        is acted on; one whose first try failed is retried every minute for 72 hours, then waits
        here as <strong>abandoned</strong> until someone presses retry.
      </p>
      {error && !rows ? (
        <EmptyState title="Could not load the notifications"><span className="u-faint">{error}</span></EmptyState>
      ) : !rows ? (
        <div style={{ padding: "var(--s6)" }}><Skeleton h={120} /></div>
      ) : rows.length === 0 ? (
        <EmptyState title={openOnly ? "Every notice has been acted on" : "Apple has sent nothing yet"}>
          {!openOnly && <span className="u-faint">Set the Server Notifications URL in App Store Connect to /v1/iap/apple/notify.</span>}
        </EmptyState>
      ) : (
        <TableWrap>
          <Table>
            <thead>
              <tr><th>received</th><th>what</th><th>store</th><th>transaction</th><th>state</th><th className={numCell}>tries</th><th>outcome</th><th /></tr>
            </thead>
            <tbody>
              {rows.map((n) => (
                <tr key={n.id}>
                  <td className="u-dim">{when(n.received_at)}</td>
                  <td>
                    <div className={s.twoLine}>
                      <span className="u-mono">{n.type}</span>
                      {n.subtype && <span className="u-mono u-faint">{n.subtype}</span>}
                    </div>
                  </td>
                  <td>{n.environment === "Production" ? <span className="u-faint">Production</span> : <Pill tone="synthetic" dot hollow>SANDBOX</Pill>}</td>
                  <td className="u-mono u-faint">{n.transaction_id || "—"}</td>
                  <td>
                    <div className={s.twoLine}>
                      <Pill tone={NOTICE_TONE[n.status]} dot hollow={n.status !== "done"}>{n.status}</Pill>
                      {n.status === "pending" && n.next_attempt_at && (
                        <span className="u-faint">next try {shortDate(n.next_attempt_at).slice(11)}</span>
                      )}
                    </div>
                  </td>
                  <td className={numCell}>{num(n.attempts)}</td>
                  <td style={{ whiteSpace: "normal", maxWidth: 320 }}>
                    {n.last_error && !n.processed_at
                      ? <span className="u-mono" style={{ color: "var(--down)", fontSize: "var(--t-small)" }}>{n.last_error}</span>
                      : <span className="u-dim">{n.outcome || "—"}</span>}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    {canRetry && n.status !== "done" && (
                      <Button size="sm" variant="quiet" busy={pending.has(`retry:${n.id}`)} onClick={() => void retry(n)}>retry</Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableWrap>
      )}
    </Panel>
  );
}

/* ------------------------------------------------------------------- page --- */

export function BillingView() {
  const [days, setDays] = useState(30);
  return (
    <div className={s.page}>
      <div className={s.filters}>
        <Field label="window">
          <select id="billing-window" value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {WINDOWS.map((d) => <option key={d} value={d}>last {d} days</option>)}
          </select>
        </Field>
        <p className="u-faint" style={{ margin: 0, maxWidth: 640 }}>
          Revenue is the App Store&rsquo;s Production purchases, by the day they were bought, in the
          price tier&rsquo;s US dollars. Sandbox purchases are listed and never counted.
        </p>
      </div>
      <Takings days={days} />
      <Transactions />
      <Notifications />
    </div>
  );
}
