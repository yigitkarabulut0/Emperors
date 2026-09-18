"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { num } from "@/lib/format";
import s from "./detail.module.css";

type Row = {
  id: number; delta: number; gross: number; balance_after: number; debt_after: number;
  reason: string; class: string; ref: string; at: string;
};

const PAGE = 50;

const CLASS: Record<string, "ok" | "gold" | "synthetic" | "neutral" | "bad"> = {
  earned: "ok", purchased: "gold", admin: "synthetic", spent: "neutral", refund: "bad", opening: "neutral",
};

/**
 * A player's diamond history, newest first: every grant, spend and refund.
 *
 * `stamp` changes after a write on the page, so a grant made above appears here
 * without a reload. `owes` is the player's refund debt as the server reads it
 * off their row (the newest ledger row's debt_after is the same number: the
 * reconciliation the server proves after every write is that equality).
 */
export function DiamondLedger({ id, stamp, owes }: { id: string; stamp: number; owes: number }) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [offset, setOffset] = useState(0);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (off: number) => {
    setBusy(true);
    const res = await query<{ rows: Row[] }>("playerDiamonds", { id, limit: PAGE, offset: off });
    if (res.ok) { setRows(res.data.rows ?? []); setError(null); } else setError(res.message);
    setBusy(false);
  }, [id]);

  useEffect(() => { void load(offset); }, [load, offset, stamp]);

  return (
    <Panel
      title="Diamonds, line by line"
      flush
      actions={
        <span className="u-row">
          {owes > 0 && (
            <Pill tone="bad" dot title="Left by a refund; repaid first out of every diamond they earn">
              owes {num(owes)}
            </Pill>
          )}
          <Button size="sm" variant="quiet" disabled={offset === 0 || busy} onClick={() => setOffset(Math.max(0, offset - PAGE))}>
            newer
          </Button>
          <Button size="sm" variant="quiet" disabled={!rows || rows.length < PAGE || busy} onClick={() => setOffset(offset + PAGE)}>
            older
          </Button>
        </span>
      }
    >
      <p className={s.explain} style={{ margin: "var(--s5) var(--s6)" }}>
        Δ is what the balance did. Gross is what was granted or spent: a grant to a player who
        owes diamonds from a refund pays the debt first, so its Δ is smaller than its gross.
      </p>
      {error ? (
        <EmptyState title="Could not load the diamond history"><span className="u-faint">{error}</span></EmptyState>
      ) : !rows ? (
        <div style={{ padding: "var(--s6)" }}><Skeleton h={120} /></div>
      ) : rows.length === 0 ? (
        <EmptyState title={offset === 0 ? "No diamond has moved for this player" : "Nothing older"} />
      ) : (
        <TableWrap>
          <Table>
            <thead>
              <tr>
                <th>when (utc)</th><th>reason</th><th className={numCell}>Δ</th>
                <th className={numCell}>gross</th><th className={numCell}>balance</th>
                <th className={numCell}>debt</th><th>ref</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td className="u-faint u-mono">{r.at}</td>
                  <td>
                    <span className="u-row">
                      <Pill tone={CLASS[r.class] ?? "neutral"}>{r.class}</Pill>
                      <span>{r.reason}</span>
                    </span>
                  </td>
                  <td className={numCell} style={{ color: r.delta > 0 ? "var(--up)" : r.delta < 0 ? "var(--down)" : "var(--text-3)" }}>
                    {r.delta > 0 ? "+" : ""}{num(r.delta)}
                  </td>
                  <td className={numCell} style={{ color: r.gross === r.delta ? "var(--text-3)" : "var(--text-2)" }}>
                    {r.gross > 0 ? "+" : ""}{num(r.gross)}
                  </td>
                  <td className={numCell}>{num(r.balance_after)}</td>
                  <td className={numCell} style={{ color: r.debt_after > 0 ? "var(--down)" : "var(--text-3)" }}>
                    {num(r.debt_after)}
                  </td>
                  <td className="u-faint u-mono" style={{ fontSize: "var(--t-micro)" }}>
                    <span className="u-truncate" style={{ display: "block", maxWidth: 220 }} title={r.ref}>{r.ref || "—"}</span>
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
