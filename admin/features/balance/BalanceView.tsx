"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { atLeast } from "@/lib/ops";
import { shortDate } from "@/lib/format";

type Version = { id: number; note: string; created_by: string; created_at: string; bytes: number; live: boolean };

export function BalanceView() {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();

  const [doc, setDoc] = useState<string>("");
  const [version, setVersion] = useState<number | null>(null);
  const [versions, setVersions] = useState<Version[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [jsonError, setJsonError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [b, v] = await Promise.all([
      query<{ version: number; document: unknown }>("balance"),
      query<{ versions: Version[] }>("balanceVersions"),
    ]);
    if (b.ok) { setDoc(JSON.stringify(b.data.document, null, 2)); setVersion(b.data.version); }
    else setError(b.message);
    if (v.ok) setVersions(v.data.versions ?? []);
  }, []);

  useEffect(() => { void load(); }, [load]);

  const canDesign = me ? atLeast(me.role, "designer") : false;

  function validate(text: string) {
    setDoc(text);
    if (!text.trim()) { setJsonError(null); return; }
    try { JSON.parse(text); setJsonError(null); }
    catch (e) { setJsonError(String(e).replace(/^SyntaxError:\s*/, "")); }
  }

  async function publish() {
    let parsed: unknown;
    try { parsed = JSON.parse(doc); }
    catch (e) { setJsonError(String(e)); return; }
    const note = (document.getElementById("balance-note") as HTMLInputElement)?.value ?? "";
    const res = await mutate("balancePublish", { document: parsed, note }, { key: "publish", success: "published; it is live now" });
    if (res.ok) await load();
  }

  async function rollback(v: Version) {
    if (!confirm(`Make version ${v.id} live again? Every player is on it within a minute.`)) return;
    const res = await mutate("balanceRollback", { version_id: v.id, reason: "rolled back from the panel" },
      { key: "rollback", success: `version ${v.id} is live` });
    if (res.ok) await load();
  }

  if (error) return <EmptyState title="Could not load the balance document"><span className="u-faint">{error}</span></EmptyState>;
  if (!doc && !versions) return <div style={{ display: "grid", gap: "var(--s6)" }}><Skeleton h={320} /></div>;

  return (
    <div style={{ display: "grid", gap: "var(--s6)", maxWidth: 1100 }}>
      <Panel
        title="The live balance document"
        actions={version != null ? <Pill tone="gold">version {version}</Pill> : null}
      >
        <p style={{ fontSize: "var(--t-small)", color: "var(--text-3)", borderLeft: "2px solid var(--hair-strong)", paddingLeft: "var(--s5)", marginBottom: "var(--s5)" }}>
          Publishing writes a new sealed version and swaps it in live — no restart, no deploy.
          The server validates it first and refuses anything that would break the economy, so a
          bad edit is a 400 with a reason rather than a broken game.
        </p>
        <textarea
          value={doc}
          onChange={(e) => validate(e.target.value)}
          rows={24}
          spellCheck={false}
          style={{ width: "100%" }}
          aria-invalid={!!jsonError}
        />
        {jsonError && <div style={{ color: "var(--down)", fontSize: "var(--t-small)", marginTop: "var(--s3)" }}>{jsonError}</div>}
        {canDesign && (
          <div style={{ display: "flex", gap: "var(--s5)", alignItems: "flex-end", marginTop: "var(--s5)", flexWrap: "wrap" }}>
            <div style={{ flex: 1, minWidth: 200 }}>
              <Field label="why" hint="Recorded against the version forever.">
                <input id="balance-note" placeholder="raised job payouts 10%" style={{ width: "100%" }} />
              </Field>
            </div>
            <Button variant="primary" busy={pending.has("publish")} disabled={!!jsonError} onClick={publish}>
              Publish
            </Button>
          </div>
        )}
      </Panel>

      <Panel title="History" flush>
        {!versions?.length ? (
          <EmptyState title="Nothing has been published yet" />
        ) : (
          <TableWrap>
            <Table>
              <thead>
                <tr>
                  <th className={numCell}>version</th><th>why</th><th>by</th>
                  <th>when</th><th className={numCell}>size</th><th />
                </tr>
              </thead>
              <tbody>
                {versions.map((v) => (
                  <tr key={v.id}>
                    <td className={numCell} style={{ color: "var(--gold-3)" }}>{v.id}</td>
                    <td className="u-dim">{v.note || "—"}</td>
                    <td className="u-faint">{v.created_by}</td>
                    <td className="u-faint">{shortDate(v.created_at)}</td>
                    <td className={numCell} style={{ color: "var(--text-3)" }}>
                      {v.bytes ? (v.bytes / 1024).toFixed(1) + " kB" : "—"}
                    </td>
                    <td>
                      {v.live
                        ? <Pill tone="ok" dot>live</Pill>
                        : canDesign
                          ? <Button size="sm" busy={pending.has("rollback")} onClick={() => rollback(v)}>make live</Button>
                          : null}
                    </td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </TableWrap>
        )}
      </Panel>
    </div>
  );
}
