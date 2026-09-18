"use client";

import { Fragment, useCallback, useEffect, useState } from "react";
import { query, useMutate, useNowTick, useSlice } from "@/store/react";
import { atLeast } from "@/lib/ops";
import { Button, EmptyState, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { ago, num, parseUTC } from "@/lib/format";

type Job = {
  name: string; period: string; claimed_at: string; claimed_by: string;
  finished_at: string; last_ok_at: string; last_error: string;
  runs: number; failures: number;
};

/** What each job does, in the words its schedule in service/jobs_list.go uses. */
const WHAT: Record<string, string> = {
  reputation_decay: "Kingdom reputation decays once per UTC day. Never retried.",
  leaderboards: "Rebuilds the rankings every five minutes.",
  mail_purge: "Deletes letters thrown away or expired past the keep window.",
  deleted_ledger_purge: "Removes a deleted account's diamond history 90 days after it left.",
  analytics_purge: "Drops the phone's events after 180 days and play days after 400.",
  iap_notifications: "Retries App Store notifications whose first try failed, every minute, for 72 hours.",
  cosmetics_lapse: "Takes off frames and colours a lord no longer holds (a lapsed patronage) so every list shows them true.",
  referral_rewards: "Pays both lords, by letter, when a friend they brought reaches the reward level.",
  promo_failures_purge: "Forgets wrong promo codes after a day; the allowance only looks back an hour.",
  kpi_rollup: "Rolls up yesterday and the two days before for Analytics' Day by day, at 01:00 UTC.",
  winback: "Hourly: a welcome-back letter to every lord away three days or more, and a second with diamonds past fourteen. One per absence.",
  hourly_events: "Every minute: writes down the hour running and the next as the roll has them, so a publish mid-hour changes nothing running or announced. Keeps two days of lords' uses.",
  festivals_close: "Every five minutes: closes a festival that has ended — its places paid by letter, with whatever each lord left unclaimed.",
  boards_close: "Every ten minutes: pays the week's boards once the UTC week turns, and a season's boards, nobility and leftover Charters once it ends.",
  deeds_backfill: "Once per database: raises the lifetime counters to what the records kept before them show, for the deeds.",
};

type Dev = { available: boolean };

/** A claim unfinished for this long is probably a process that died mid-run. A
 *  new one takes it over once the job's lease runs out. */
const STUCK_AFTER_S = 30 * 60;

function State({ j, now }: { j: Job; now: number }) {
  if (!j.finished_at) {
    const since = parseUTC(j.claimed_at);
    const s = since ? (now - since.getTime()) / 1000 : 0;
    return s > STUCK_AFTER_S
      ? <Pill tone="bad" dot hollow title="Claimed and never finished. Another process takes it over when its lease runs out.">stuck?</Pill>
      : <Pill tone="warn" dot>running</Pill>;
  }
  if (j.last_error) {
    // A retrying job clears its period so the next tick claims it again; a job
    // that does not retry keeps the period, and that period's run is lost.
    return j.period === ""
      ? <Pill tone="bad" dot title="Retries on the next tick">failed · retrying</Pill>
      : <Pill tone="bad" dot hollow title="This job does not retry; the period's run is lost">failed</Pill>;
  }
  return <Pill tone="ok" dot>ok</Pill>;
}

function When({ stamp, now }: { stamp: string; now: number }) {
  const d = parseUTC(stamp);
  if (!d) return <span className="u-faint">—</span>;
  return <span title={`${stamp} UTC`}>{ago((now - d.getTime()) / 1000)}</span>;
}

export function JobsView() {
  const now = useNowTick();
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [dev, setDev] = useState(false);
  useEffect(() => {
    void query<Dev>("dev").then((res) => setDev(res.ok && res.data.available));
  }, []);
  const canRun = dev && (me ? atLeast(me.role, "designer") : false);
  const [jobs, setJobs] = useState<Job[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setBusy(true);
    const res = await query<{ jobs: Job[] }>("jobs");
    if (res.ok) { setJobs(res.data.jobs ?? []); setError(null); } else setError(res.message);
    setBusy(false);
  }, []);

  // The runner ticks every thirty seconds, so the board does too.
  useEffect(() => {
    void load();
    const id = setInterval(() => void load(), 30_000);
    return () => clearInterval(id);
  }, [load]);

  if (error && !jobs) {
    return <EmptyState title="Could not load the jobs"><span className="u-faint">{error}</span></EmptyState>;
  }

  const failing = (jobs ?? []).filter((j) => j.finished_at && j.last_error).length;

  return (
    <div style={{ display: "grid", gap: "var(--s6)", maxWidth: 1100 }}>
      <Panel
        title="Scheduled jobs"
        flush
        actions={
          <span className="u-row">
            {failing > 0 && <Pill tone="bad" dot>{failing} failing</Pill>}
            <Button size="sm" variant="quiet" busy={busy} onClick={() => void load()}>refresh</Button>
          </span>
        }
      >
        <div style={{ padding: "var(--s5) var(--s6)", borderBottom: "1px solid var(--hair)" }} className="u-faint">
          Each job runs once per period, across restarts and every server process: the first to
          claim a period runs it. The period is what the job last claimed — a day, or a
          five-minute window. The board refreshes every thirty seconds, as the runner ticks.
        </div>
        {!jobs ? (
          <div style={{ padding: "var(--s6)" }}><Skeleton h={160} /></div>
        ) : jobs.length === 0 ? (
          <EmptyState title="No job has run yet">
            <span className="u-faint">The runner claims its first period within thirty seconds of the server starting.</span>
          </EmptyState>
        ) : (
          <TableWrap>
            <Table>
              <thead>
                <tr>
                  <th>job</th><th>state</th><th>period</th><th>claimed</th><th>by</th>
                  <th>finished</th><th>last ok</th><th className={numCell}>runs</th>
                  <th className={numCell}>failures</th>
                  {canRun && <th />}
                </tr>
              </thead>
              <tbody>
                {jobs.map((j) => (
                  <Fragment key={j.name}>
                  <tr>
                    <td title={WHAT[j.name] ?? ""}>
                      <span className="u-mono">{j.name}</span>
                    </td>
                    <td><State j={j} now={now} /></td>
                    <td className="u-mono u-faint">{j.period || "—"}</td>
                    <td className="u-dim"><When stamp={j.claimed_at} now={now} /></td>
                    <td className="u-mono u-faint" style={{ fontSize: "var(--t-micro)" }}>{j.claimed_by}</td>
                    <td className="u-dim"><When stamp={j.finished_at} now={now} /></td>
                    <td className="u-dim"><When stamp={j.last_ok_at} now={now} /></td>
                    <td className={numCell}>{num(j.runs)}</td>
                    <td className={numCell} style={{ color: j.failures > 0 ? "var(--down)" : "var(--text-3)" }}>
                      {num(j.failures)}
                    </td>
                    {canRun && (
                      <td style={{ textAlign: "right" }}>
                        <Button size="sm" variant="quiet" busy={pending.has("run:" + j.name)}
                          title="Dev server only: runs it now, outside its schedule"
                          onClick={async () => {
                            const res = await mutate("devRunJob", { name: j.name }, { key: "run:" + j.name, success: `${j.name} ran` });
                            if (res.ok) void load();
                          }}>run now</Button>
                      </td>
                    )}
                  </tr>
                  {/* The last error in full, on its own line under its job: an
                      error is read, and a truncated one in a narrow column is not. */}
                  {j.last_error && (
                    <tr>
                      <td colSpan={canRun ? 10 : 9} style={{ whiteSpace: "normal", height: "auto", padding: "var(--s3) var(--s5) var(--s4)" }}>
                        <span className="u-micro" style={{ color: "var(--down)" }}>last error</span>{" "}
                        <span className="u-mono" style={{ fontSize: "var(--t-small)", color: "var(--text-2)" }}>{j.last_error}</span>
                      </td>
                    </tr>
                  )}
                  </Fragment>
                ))}
              </tbody>
            </Table>
          </TableWrap>
        )}
      </Panel>
      {jobs && jobs.length > 0 && (
        <Panel title="What each job does">
          <table style={{ width: "100%" }}>
            <tbody>
              {jobs.map((j) => (
                <tr key={j.name}>
                  <td className="u-mono" style={{ padding: "var(--s2) var(--s5) var(--s2) 0", whiteSpace: "nowrap", verticalAlign: "top" }}>{j.name}</td>
                  <td className="u-faint" style={{ padding: "var(--s2) 0" }}>{WHAT[j.name] ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Panel>
      )}
    </div>
  );
}
