"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { query } from "@/store/react";
import { EmptyState, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap } from "@/ui/Table";
import { shortDate } from "@/lib/format";

type Entry = { id?: number; admin: string; action: string; subject: string; note: string; at: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function AuditView() {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    void (async () => {
      const res = await query<{ entries: Entry[] }>("audit", { limit: 100 });
      if (res.ok) { setEntries(res.data.entries ?? []); setError(null); } else setError(res.message);
    })();
  }, []);

  if (error) return <EmptyState title="Could not load the audit trail"><span className="u-faint">{error}</span></EmptyState>;
  if (!entries) return <Skeleton h={280} />;

  const shown = filter
    ? entries.filter((e) =>
        `${e.admin} ${e.action} ${e.subject} ${e.note}`.toLowerCase().includes(filter.toLowerCase()))
    : entries;

  return (
    <Panel
      title="Everything anyone has done"
      flush
      actions={
        <input
          placeholder="filter"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          style={{ height: 26, width: 200 }}
        />
      }
    >
      {shown.length === 0 ? (
        <EmptyState title={filter ? `Nothing matches “${filter}”` : "Nothing has been done yet"} />
      ) : (
        <TableWrap>
          <Table>
            <thead>
              <tr><th>when</th><th>admin</th><th>action</th><th>subject</th><th>why</th></tr>
            </thead>
            <tbody>
              {shown.map((e, i) => (
                <tr key={e.id ?? i}>
                  <td className="u-faint">{shortDate(e.at)}</td>
                  <td className="u-dim">{e.admin}</td>
                  <td><Pill>{e.action}</Pill></td>
                  <td className="u-mono" style={{ fontSize: "var(--t-micro)" }}>
                    {UUID.test(e.subject)
                      ? <Link href={`/players/${e.subject}`} style={{ color: "var(--gold-3)" }}>{e.subject.slice(0, 8)}…</Link>
                      : e.subject || "—"}
                  </td>
                  <td className="u-faint">{e.note || "—"}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        </TableWrap>
      )}
    </Panel>
  );
}
