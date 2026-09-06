"use client";

import { useState } from "react";
import { createBoost, revokeBoost } from "@/app/actions";
import { ActionForm, ActionButton } from "@/app/_ui/Inline";

export type Boost = {
  id: number; bucket: string; amount_bp: number; starts_at: string; ends_at: string;
  note: string; created_by: string; live: boolean; revoked: boolean;
};
export type Bucket = { bucket: string; label: string; help: string; cap_bp: number };

const pct = (bp: number) => `${bp > 0 ? "+" : ""}${(bp / 100).toFixed(0)}%`;

export function EventsClient({ boosts, buckets }: { boosts: Boost[]; buckets: Bucket[] }) {
  const [rows, setRows] = useState(boosts);
  const [bucket, setBucket] = useState(buckets[0]?.bucket ?? "");
  const chosen = buckets.find((b) => b.bucket === bucket);

  return (
    <>
      <div className="card">
        <h2>Start an event</h2>
        <p className="muted">
          Everyone at once, for a fixed window. Events feed the same buckets as
          family upgrades and job mastery, so each keeps its own cap — an event can
          lift players toward a ceiling, never past one the game&rsquo;s own upgrades
          could already reach.
        </p>

        <ActionForm
          submit="Start event"
          onDone={(r) => {
            const d = (r as { data?: Boost }).data;
            if (r.ok && d) setRows((cur) => [d, ...cur]);
          }}
          run={async (fd) =>
            createBoost(
              String(fd.get("bucket")),
              Number(fd.get("amount_bp") || 0),
              Number(fd.get("hours") || 0),
              String(fd.get("note") || ""),
            )
          }
        >
          <select name="bucket" value={bucket} onChange={(e) => setBucket(e.target.value)}>
            {buckets.map((b) => <option key={b.bucket} value={b.bucket}>{b.label}</option>)}
          </select>
          <input name="amount_bp" placeholder="bonus (bp)" defaultValue={5000} style={{ width: 130 }} />
          <input name="hours" placeholder="hours" defaultValue={48} style={{ width: 100 }} />
          <input name="note" placeholder="what this is for" style={{ flex: 1, minWidth: 200 }} />
        </ActionForm>

        {chosen ? (
          <p className="muted" style={{ marginTop: 10 }}>
            <strong>{chosen.label}.</strong> {chosen.help}
            {chosen.cap_bp ? ` This bucket caps at ${(chosen.cap_bp / 100).toFixed(0)}% in total.` : ""}
          </p>
        ) : null}
        <p className="faint" style={{ marginTop: 6, fontSize: 12 }}>
          5000 bp is +50%. Energy regeneration is not on this list on purpose: it is
          the one lever that bounds the whole gold supply, so it belongs in a
          balance publish, which is versioned and can be rolled back.
        </p>
      </div>

      <div className="card">
        <h2>Events</h2>
        {rows.length === 0 ? <p className="empty">None yet.</p> : (
          <table>
            <thead>
              <tr>
                <th>WHAT</th><th className="num">BONUS</th><th>WINDOW</th>
                <th>BY</th><th>NOTE</th><th>STATE</th><th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((b) => {
                const label = buckets.find((x) => x.bucket === b.bucket)?.label ?? b.bucket;
                return (
                  <tr key={b.id}>
                    <td>{label}</td>
                    <td className="num">{pct(b.amount_bp)}</td>
                    <td className="muted">{b.starts_at} → {b.ends_at}</td>
                    <td className="muted">{b.created_by}</td>
                    <td>{b.note}</td>
                    <td>
                      {b.revoked ? <span className="pill">ended</span>
                        : b.live ? <span className="pill ok">live</span>
                        : <span className="pill">scheduled</span>}
                    </td>
                    <td>
                      {b.live ? (
                        <ActionButton
                          label="End now" danger
                          confirm={`End "${label} ${pct(b.amount_bp)}" for everyone?`}
                          onDone={(r) => {
                            if (r.ok) setRows((cur) => cur.map((x) =>
                              x.id === b.id ? { ...x, live: false, revoked: true } : x));
                          }}
                          run={() => revokeBoost(b.id)}
                        />
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
        <p className="muted" style={{ marginTop: 10 }}>
          Ended, never deleted — &ldquo;why was everyone earning double on the 14th&rdquo;
          has to stay answerable long afterwards.
        </p>
      </div>
    </>
  );
}
