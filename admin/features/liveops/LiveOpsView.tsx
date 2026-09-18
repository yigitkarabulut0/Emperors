"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { bp, num } from "@/lib/format";
import s from "./liveops.module.css";

// The realm's calendar (service/liveops_desk.go): the hour's event, rolled at
// the top of every hour from the published table and settable a day ahead;
// the festivals, scheduled off their templates and frozen as they stand; and
// the season with its Royal Charter, its boards and its closes.

type HourSlot = {
  hour: number; starts_at: string; event_id: string; name: string; icon: string; minutes: number;
  source: "roll" | "forced" | "skipped" | "predicted"; set_by?: string; note?: string;
  current: boolean; settable: boolean; lords: number;
};
type HourlyRow = { id: string; name: string; blurb: string; minutes: number; bp: number };
type Festival = {
  id: number; template_id: string; name: string; theme: string; bucket: string; bp: number;
  starts_at: string; ends_at: string; status: "scheduled" | "running" | "closing" | "closed" | "revoked";
  lords: number; note: string; created_by: string; revoked_by?: string;
};
type Template = { id: string; name: string; theme: string; blurb: string; days: number; bucket: string; bp: number };
type Standing = { place: number; player_id: string; name: string; level: number; points: number };
type Season = {
  number: number; starts_at: string; ends_at: string; day: number; days: number;
  lords: number; royal: number; royal_bought: number; points: number; top_points: number;
  bands: { from: number; to: number; lords: number }[];
  top: Standing[];
  closes: { what: string; period: number; closed_at: string; lords: number }[];
};

const BUCKET: Record<string, string> = {
  collect_income_bp: "gold", xp_bp: "experience", reputation_bp: "renown", shop_discount_bp: "market discount",
};

const SOURCE_TONE = { roll: "neutral", forced: "gold", skipped: "warn", predicted: "neutral" } as const;

export function LiveOpsView() {
  const me = useSlice("me");
  const canDesign = me ? atLeast(me.role, "designer") : false;
  return (
    <div className={s.page}>
      <HourlyPanel canDesign={canDesign} />
      <FestivalsPanel canDesign={canDesign} />
      <SeasonPanel />
    </div>
  );
}

/* ------------------------------------------------------------ the hour --- */

function HourlyPanel({ canDesign }: { canDesign: boolean }) {
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [hours, setHours] = useState<HourSlot[] | null>(null);
  const [table, setTable] = useState<HourlyRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [choice, setChoice] = useState<Record<number, string>>({});

  const load = useCallback(async () => {
    const res = await query<{ hours: HourSlot[]; table: HourlyRow[] }>("liveopsHourly");
    if (res.ok) {
      setHours(res.data.hours ?? []);
      setTable(res.data.table ?? []);
      setError(null);
    } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function set(h: HourSlot) {
    const event = choice[h.hour] ?? "";
    const label = event === "" ? "back to the roll" : event === "none" ? "a quiet hour" : table.find((t) => t.id === event)?.name ?? event;
    const res = await mutate("liveopsSetHour", { hour: h.hour, event, note: "" }, {
      key: "hour:" + h.hour, success: `${h.starts_at} utc: ${label}`,
    });
    if (res.ok) await load();
  }

  const ahead = (hours ?? []).filter((h) => h.current || h.settable);
  const behind = (hours ?? []).filter((h) => !h.current && !h.settable).reverse();
  const odds = table.reduce((n, t) => n + t.bp, 0);

  const row = (h: HourSlot) => (
    <tr key={h.hour} className={h.current ? s.now : undefined}>
      <td className={s.mono}>{h.starts_at.slice(5)}</td>
      <td>
        {h.event_id === "none" ? <span className="u-faint">quiet hour</span> : <b>{h.name}</b>}
        {h.minutes > 0 && <span className="u-faint"> · {h.minutes} min</span>}
      </td>
      <td>
        <Pill tone={SOURCE_TONE[h.source]} dot hollow={h.source === "predicted"}
          title={h.source === "predicted" ? "not yet written down: what the roll will say unless it is set" : h.note || undefined}>
          {h.current ? "now · " : ""}{h.source}{h.set_by ? ` · ${h.set_by}` : ""}
        </Pill>
      </td>
      <td className={s.num}>{h.lords > 0 ? num(h.lords) : <span className="u-faint">—</span>}</td>
      <td>
        {canDesign && h.settable && (
          <div className={s.setter}>
            <select value={choice[h.hour] ?? (h.source === "forced" ? h.event_id : h.source === "skipped" ? "none" : "")}
              onChange={(e) => setChoice({ ...choice, [h.hour]: e.target.value })}>
              <option value="">the roll</option>
              <option value="none">a quiet hour</option>
              {table.filter((t) => t.id !== "none").map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
            <Button size="sm" busy={pending.has("hour:" + h.hour)} onClick={() => set(h)}>set</Button>
          </div>
        )}
      </td>
    </tr>
  );

  return (
    <Panel title="The hour" flush>
      {error ? (
        <EmptyState title="Could not load the schedule"><span className="u-faint">{error}</span></EmptyState>
      ) : !hours ? (
        <div style={{ padding: "var(--s6)" }}><Skeleton h={160} /></div>
      ) : (
        <>
          <p className={s.lede}>
            Every hour rolls one event from the published table ({table.length - 1} events and a quiet hour,
            {odds === 10000 ? " 10,000 bp in all" : ` ${num(odds)} bp — not 10,000`}), never the same twice
            running. It lasts its minutes from the top of the hour. Set an hour that has not begun, up to a day
            ahead; the hour after a forced one still will not repeat it.
          </p>
          <div className={s.odds}>
            {table.map((t) => (
              <span key={t.id} className={s.odd} title={t.blurb}>
                <b>{t.id === "none" ? "quiet" : t.name}</b> {bp(t.bp).replace("+", "")}
              </span>
            ))}
          </div>
          <table className={s.table}>
            <thead>
              <tr><th>utc</th><th>event</th><th>written</th><th className={s.num}>lords used it</th><th /></tr>
            </thead>
            <tbody>{ahead.map(row)}</tbody>
          </table>
          <details className={s.past}>
            <summary>The day behind ({behind.length} hours)</summary>
            <table className={s.table}><tbody>{behind.map(row)}</tbody></table>
          </details>
        </>
      )}
    </Panel>
  );
}

/* ------------------------------------------------------- the festivals --- */

function FestivalsPanel({ canDesign }: { canDesign: boolean }) {
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [rows, setRows] = useState<Festival[] | null>(null);
  const [templates, setTemplates] = useState<Template[]>([]);
  const [announce, setAnnounce] = useState(72);
  const [error, setError] = useState<string | null>(null);
  const [template, setTemplate] = useState("");
  const [startsIn, setStartsIn] = useState(24);
  const [startsAt, setStartsAt] = useState("");
  const [note, setNote] = useState("");
  const [board, setBoard] = useState<{ id: number; rows: Standing[] } | null>(null);

  const load = useCallback(async () => {
    const res = await query<{ festivals: Festival[]; templates: Template[]; announce_hours: number }>("liveopsFestivals");
    if (res.ok) {
      setRows(res.data.festivals ?? []);
      setTemplates(res.data.templates ?? []);
      setAnnounce(res.data.announce_hours ?? 72);
      setError(null);
    } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!template && templates.length) setTemplate(templates[0].id);
  }, [templates, template]);

  const tpl = templates.find((t) => t.id === template);
  const startMs = startsAt.trim()
    ? Date.parse(startsAt.trim().replace(" ", "T") + ":00Z")
    : Date.now() + startsIn * 3600_000;
  const stamp = (ms: number) => (Number.isFinite(ms) ? new Date(ms).toISOString().slice(0, 16).replace("T", " ") : "—");
  const endMs = startMs + (tpl?.days ?? 0) * 86400_000;
  const clash = (rows ?? []).find((f) =>
    (f.status === "scheduled" || f.status === "running") &&
    Date.parse(f.starts_at.replace(" ", "T") + ":00Z") < endMs && Date.parse(f.ends_at.replace(" ", "T") + ":00Z") > startMs);

  async function schedule() {
    const res = await mutate("festivalSchedule", {
      template, starts_at: startsAt.trim(), starts_in_hours: startsAt.trim() ? 0 : startsIn, note,
    }, { key: "festival", success: `${tpl?.name ?? template} from ${stamp(startMs)} utc` });
    if (res.ok) { setNote(""); await load(); }
  }

  async function revoke(f: Festival) {
    const ask = f.status === "running"
      ? `End the ${f.name} now? Its bonus stops for everyone, and nothing more is paid — no places, no leftovers.`
      : `Cancel the ${f.name}? It will not start, and the game stops announcing it.`;
    if (!confirm(ask)) return;
    const res = await mutate("festivalRevoke", { id: f.id }, { key: "fest:" + f.id, success: `${f.name} taken off the calendar` });
    if (res.ok) await load();
  }

  async function showBoard(f: Festival) {
    if (board?.id === f.id) { setBoard(null); return; }
    const res = await query<{ board: Standing[] }>("liveopsFestivalBoard", { id: f.id });
    if (res.ok) setBoard({ id: f.id, rows: res.data.board ?? [] });
  }

  return (
    <>
      {canDesign && (
        <Panel title="Schedule a festival">
          <div className={s.form}>
            <div className={s.fields}>
              <Field label="festival">
                <select value={template} onChange={(e) => setTemplate(e.target.value)} style={{ minWidth: 200 }}>
                  {templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </Field>
              <Field label="starts in (hours)" hint={<span className={s.readout}>{startsAt.trim() ? "set below" : `${stamp(startMs)} utc`}</span>}>
                <input type="number" value={startsIn} min={0} max={1440} disabled={!!startsAt.trim()}
                  onChange={(e) => setStartsIn(Math.max(0, Math.trunc(Number(e.target.value) || 0)))} />
              </Field>
              <Field label="or at (utc)" hint={<span className={s.readout}>YYYY-MM-DD HH:MM</span>}>
                <input value={startsAt} placeholder="2026-09-26 18:00" onChange={(e) => setStartsAt(e.target.value)} style={{ width: 170 }} />
              </Field>
              <Field label="ends" hint={<span className={s.readout}>{tpl ? `${tpl.days} days` : ""}</span>}>
                <input value={stamp(endMs)} readOnly style={{ width: 170 }} />
              </Field>
            </div>
            {tpl && (
              <p className={s.help}>
                {tpl.blurb} While it runs every lord gets {bp(tpl.bp)} {BUCKET[tpl.bucket] ?? tpl.bucket}. Frozen as the
                balance stands when you schedule it: a publish during it changes nothing its lords play for. The
                game announces it {announce} hours before it starts.
              </p>
            )}
            {clash && <p className={s.warn}>It would run over the {clash.name} ({clash.starts_at} → {clash.ends_at}); the server will refuse it.</p>}
            <div className={s.inline}>
              <div className={s.note}>
                <Field label="why"><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="autumn harvest" style={{ width: "100%" }} /></Field>
              </div>
              <Button variant="primary" busy={pending.has("festival")} disabled={!tpl || !!clash} onClick={schedule}>Schedule it</Button>
            </div>
          </div>
        </Panel>
      )}

      <Panel title="Festivals" flush>
        {error ? (
          <EmptyState title="Could not load the festivals"><span className="u-faint">{error}</span></EmptyState>
        ) : !rows ? (
          <div style={{ padding: "var(--s6)" }}><Skeleton h={100} /></div>
        ) : rows.length === 0 ? (
          <EmptyState title="No festival has been scheduled">
            <span className="u-faint">Schedule one above; the game announces it {announce} hours before it starts.</span>
          </EmptyState>
        ) : (
          <table className={s.table}>
            <thead>
              <tr><th>festival</th><th className={s.num}>bonus</th><th>window (utc)</th><th className={s.num}>lords</th><th>by</th><th>state</th><th /></tr>
            </thead>
            <tbody>
              {rows.map((f) => (
                <FestivalRow key={f.id} f={f} canDesign={canDesign} busy={pending.has("fest:" + f.id)}
                  onRevoke={() => revoke(f)} onBoard={() => showBoard(f)} board={board?.id === f.id ? board.rows : null} />
              ))}
            </tbody>
          </table>
        )}
      </Panel>
    </>
  );
}

function FestivalRow({ f, canDesign, busy, onRevoke, onBoard, board }: {
  f: Festival; canDesign: boolean; busy: boolean; onRevoke: () => void; onBoard: () => void; board: Standing[] | null;
}) {
  const pill = {
    scheduled: <Pill tone="warn" dot hollow>scheduled</Pill>,
    running: <Pill tone="ok" dot>running</Pill>,
    closing: <Pill tone="warn" dot>closing</Pill>,
    closed: <Pill dot hollow>closed</Pill>,
    revoked: <Pill tone="bad" dot hollow>revoked{f.revoked_by ? ` · ${f.revoked_by}` : ""}</Pill>,
  }[f.status];
  return (
    <>
      <tr>
        <td><b>{f.name}</b>{f.note && <span className="u-faint"> · {f.note}</span>}</td>
        <td className={s.num} style={{ color: "var(--gold-3)" }}>{bp(f.bp)} <span className="u-faint">{BUCKET[f.bucket] ?? f.bucket}</span></td>
        <td className={`${s.mono} u-faint`}>{f.starts_at} → {f.ends_at}</td>
        <td className={s.num}>{num(f.lords)}</td>
        <td className="u-dim">{f.created_by}</td>
        <td>{pill}</td>
        <td className={s.actions}>
          {f.status !== "scheduled" && f.status !== "revoked" && <Button size="sm" onClick={onBoard}>{board ? "hide board" : "board"}</Button>}
          {canDesign && (f.status === "scheduled" || f.status === "running") && (
            <Button size="sm" variant="danger" busy={busy} onClick={onRevoke}>{f.status === "running" ? "end now" : "cancel"}</Button>
          )}
        </td>
      </tr>
      {board && (
        <tr className={s.boardRow}>
          <td colSpan={7}>
            {board.length === 0 ? <span className="u-faint">No lord has points in it yet.</span> : (
              <ol className={s.board}>
                {board.slice(0, 20).map((r) => (
                  <li key={r.player_id}>
                    <span className={s.place}>{r.place}</span>
                    <a href={`/players/${r.player_id}`}>{r.name}</a>
                    <span className="u-faint"> L{r.level}</span>
                    <span className={s.points}>{num(r.points)}</span>
                  </li>
                ))}
              </ol>
            )}
          </td>
        </tr>
      )}
    </>
  );
}

/* ---------------------------------------------------------- the season --- */

function SeasonPanel() {
  const [season, setSeason] = useState<Season | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    void (async () => {
      const res = await query<Season>("liveopsSeason");
      if (res.ok) setSeason(res.data); else setError(res.message);
    })();
  }, []);

  if (error) return <Panel title="The season"><EmptyState title="Could not load the season"><span className="u-faint">{error}</span></EmptyState></Panel>;
  if (!season) return <Panel title="The season"><Skeleton h={120} /></Panel>;
  const most = Math.max(1, ...season.bands.map((b) => b.lords));
  return (
    <Panel title={season.number >= 1 ? `Season ${season.number}` : "Before the first season"}>
      <Stats>
        <Stat label="day" value={`${season.day} of ${season.days}`} sub={`${season.starts_at} → ${season.ends_at} utc`} />
        <Stat label="lords on the Charter" value={num(season.lords)} />
        <Stat label="royal lanes" value={num(season.royal)} sub={`${num(season.royal_bought)} bought with money`} />
        <Stat label="renown earned" value={num(season.points)} sub={`the most: ${num(season.top_points)}`} />
      </Stats>
      <div className={s.seasonGrid}>
        <div>
          <h3 className={s.h3}>Lords by tier</h3>
          {season.bands.length === 0 ? <p className="u-faint">No lord has earned a point yet.</p> : (
            <div className={s.bands}>
              {season.bands.map((b) => (
                <div key={b.from} className={s.band}>
                  <span className={s.bandLabel}>{b.from === b.to ? `tier ${b.from}` : `tiers ${b.from}–${b.to}`}</span>
                  <span className={s.bar}><i style={{ width: `${(b.lords * 100) / most}%` }} /></span>
                  <span className={s.num}>{num(b.lords)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
        <div>
          <h3 className={s.h3}>Renown, the top ten</h3>
          {season.top.length === 0 ? <p className="u-faint">Nobody yet.</p> : (
            <ol className={s.board}>
              {season.top.map((r) => (
                <li key={r.player_id}>
                  <span className={s.place}>{r.place}</span>
                  <a href={`/players/${r.player_id}`}>{r.name}</a>
                  <span className="u-faint"> L{r.level}</span>
                  <span className={s.points}>{num(r.points)}</span>
                </li>
              ))}
            </ol>
          )}
        </div>
      </div>
      <h3 className={s.h3}>Closes</h3>
      {season.closes.length === 0 ? <p className="u-faint">No week or season has closed yet. The boards pay when theirs does, by letter.</p> : (
        <table className={s.table}>
          <thead><tr><th>what</th><th>period</th><th>closed (utc)</th><th className={s.num}>lords</th></tr></thead>
          <tbody>
            {season.closes.map((c) => (
              <tr key={c.what + c.period}>
                <td>{c.what.replace(/_/g, " ")}</td>
                <td className={s.mono}>{c.what.startsWith("week_") ? new Date(c.period * 86400_000).toISOString().slice(0, 10) : `season ${c.period}`}</td>
                <td className={`${s.mono} u-faint`}>{c.closed_at}</td>
                <td className={s.num}>{num(c.lords)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}
