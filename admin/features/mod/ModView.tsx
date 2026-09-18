"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { ago, num } from "@/lib/format";
import s from "./mod.module.css";

// The halls (service/social_desk.go): what has been reported in them, and the
// crown's two answers -- hide the line, silence the tongue.
//
// The queue is OLDEST FIRST on purpose. The clock a moderator is judged by
// starts when the line was said, not when somebody got round to it, so the
// oldest thing waiting is always the next thing to do; the chip beside each row
// is that clock.
//
// Two things are shown for every line: what was TYPED and what the hall SHOWED.
// The filter stars words out, and a moderator who only ever reads the starred
// version cannot tell a slip from a campaign.

type Row = {
  id: string; seq: number; room: string; kingdom: string;
  player_id?: string; name?: string; username?: string; level?: number;
  state?: string; muted_for?: number;
  body: string; shown: string;
  at: number; reports: number; reasons: string;
  hidden: boolean; hidden_by?: string; waiting_for: number;
};
type LordRow = {
  player_id: string; name?: string; username?: string; avatar?: string;
  level?: number; state?: string; kingdom?: string; muted_for?: number;
  reports: number; reasons: string; at: number; waiting_for: number;
};
type Queue = {
  rows: Row[];
  lords: LordRow[];
  said_today: number; reported: number; hidden: number; muted: number;
  friendships: number; gifts_today: number; reported_lords: number;
  reports_to_hide: number; mute_minutes: number; retention_days: number;
};
type Line = { id: string; seq: number; kind: string; name?: string; body: string; at: number; hidden?: boolean };
type Mute = {
  player_id: string; name: string; username: string; until: number;
  live: boolean; reason: string; by: string; at: number;
};

export function ModView() {
  const me = useSlice("me");
  const canJudge = me ? atLeast(me.role, "moderator") : false;
  return (
    <div className={s.page}>
      <QueuePanel canJudge={canJudge} />
      <LordsPanel canJudge={canJudge} />
      <MutesPanel canJudge={canJudge} />
    </div>
  );
}

/* ------------------------------------------------------------ the queue --- */

function QueuePanel({ canJudge }: { canJudge: boolean }) {
  const mutate = useMutate();
  const [v, setV] = useState<Queue | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [room, setRoom] = useState<Line[]>([]);

  const load = useCallback(async () => {
    const res = await query<Queue>("modQueue", { limit: 50 });
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);

  // The room around a line, so a sentence is never judged on its own.
  async function context(r: Row) {
    if (open === r.id) { setOpen(null); setRoom([]); return; }
    setOpen(r.id);
    const res = await query<{ lines: Line[] }>("modContext", { id: r.id, span: 8 });
    setRoom(res.ok ? res.data.lines : []);
  }

  async function hide(r: Row, on: boolean) {
    const res = await mutate("modHide", { id: r.id, hide: on, note: "" }, {
      key: "mod:" + r.id,
      success: on ? "the line is down" : "the line is back",
    });
    if (res.ok) await load();
  }

  async function mute(r: Row, minutes: number) {
    if (!r.player_id) return;
    const res = await mutate("modMute", {
      player_id: r.player_id, minutes, reason: "reported in the hall", note: "",
    }, { key: "mute:" + r.player_id, success: `${r.name} is silent for ${minutes} minutes` });
    if (res.ok) await load();
  }

  if (error) return <Panel title="The halls"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="The halls"><Skeleton h={140} /></Panel>;

  return (
    <Panel title="The halls" flush>
      <p className={s.lede}>
        Every line a lord reported and nobody has judged, oldest first. {v.reports_to_hide} reports
        hide a line from its room on their own; what is left here is whether it stays hidden and
        whether the tongue behind it is silenced. A silence is TIME ({v.mute_minutes} minutes by
        the hall&rsquo;s own rule) and never a fine.
      </p>
      <Stats>
        <Stat label="said today" value={num(v.said_today)} />
        <Stat label="waiting" value={num(v.reported)} muted={v.reported === 0} />
        <Stat label="hidden" value={num(v.hidden)} />
        <Stat label="silenced now" value={num(v.muted)} />
        <Stat label="lords reported" value={num(v.reported_lords)} muted={v.reported_lords === 0} />
        <Stat label="friendships" value={num(v.friendships)} />
        <Stat label="gifts today" value={num(v.gifts_today)} />
      </Stats>
      {v.rows.length === 0 ? (
        <EmptyState title="Nothing is waiting.">
          The halls keep {v.retention_days} days; anything older has been swept.
        </EmptyState>
      ) : (
        <div className={s.rows}>
          {v.rows.map((r) => (
            <div key={r.id} className={s.row}>
              <div className={s.head}>
                <b>{r.name ?? "a lord who has gone"}</b>
                {r.level ? <span className="u-faint"> Lv {r.level}</span> : null}
                <span className="u-faint"> · {r.kingdom}</span>
                <Pill tone={r.waiting_for > 3600 ? "warn" : "neutral"} dot>
                  waiting {ago(r.waiting_for)}
                </Pill>
                <Pill tone="neutral">{r.reports}× {r.reasons || "reported"}</Pill>
                {r.hidden ? <Pill tone="warn">hidden by {r.hidden_by}</Pill> : null}
                {r.muted_for ? <Pill tone="warn">silent {ago(r.muted_for)}</Pill> : null}
                {r.state && r.state !== "active" ? <Pill tone="bad">{r.state}</Pill> : null}
              </div>
              <p className={s.said}>{r.body}</p>
              {r.shown !== r.body ? (
                <p className={s.shown}>the hall showed: {r.shown}</p>
              ) : null}
              <div className={s.actions}>
                <Button onClick={() => void context(r)}>
                  {open === r.id ? "close the room" : "read the room"}
                </Button>
                {canJudge ? (
                  <>
                    <Button variant={r.hidden ? "ghost" : "danger"} onClick={() => void hide(r, !r.hidden)}>
                      {r.hidden ? "put it back" : "hide the line"}
                    </Button>
                    <Button variant="danger" onClick={() => void mute(r, v.mute_minutes)}>
                      silence an hour
                    </Button>
                    <Button variant="danger" onClick={() => void mute(r, 60 * 24)}>
                      silence a day
                    </Button>
                  </>
                ) : null}
              </div>
              {open === r.id ? (
                <div className={s.room}>
                  {room.length === 0 ? <span className="u-faint">nothing else in that stretch</span> : null}
                  {room.map((l) => (
                    <div key={l.id} className={l.id === r.id ? s.thisOne : undefined}>
                      <span className="u-faint">{l.name ?? "the realm"}: </span>
                      {l.body}
                    </div>
                  ))}
                </div>
              ) : null}
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

/* -------------------------------------------------------- reported lords --- */

// The other queue (app.lord_reports): a lord reported AS A LORD -- their name,
// their look, their play -- where there is no line to point at. There is
// nothing to read here on purpose: the judgement is about the lord, so the
// answers are the ones the desk already has (a silence, a letter, a rename
// asked for) and then "looked at", which is what clears them from the queue.
function LordsPanel({ canJudge }: { canJudge: boolean }) {
  const mutate = useMutate();
  const [v, setV] = useState<Queue | null>(null);

  const load = useCallback(async () => {
    const res = await query<Queue>("modQueue", { limit: 50 });
    if (res.ok) setV(res.data);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function clear(r: LordRow) {
    const res = await mutate("modClear", { player_id: r.player_id, note: "" }, {
      key: "clear:" + r.player_id, success: `${r.name ?? "the lord"} is answered`,
    });
    if (res.ok) await load();
  }

  async function mute(r: LordRow, minutes: number) {
    const res = await mutate("modMute", {
      player_id: r.player_id, minutes, reason: "reported to the crown", note: "",
    }, { key: "mute:" + r.player_id, success: `${r.name} is silent for ${minutes} minutes` });
    if (res.ok) await load();
  }

  if (!v) return <Panel title="Reported lords"><Skeleton h={100} /></Panel>;
  return (
    <Panel title="Reported lords" flush>
      <p className={s.lede}>
        A lord reported from their own page &mdash; their name, their look, or their play &mdash;
        where there is no line to point at. Nothing hides itself here: a name is judged by a person.
        Answering one clears every open report against that lord, whichever way it went.
      </p>
      {v.lords.length === 0 ? (
        <EmptyState title="No lord is waiting." />
      ) : (
        <table className="u-table">
          <thead><tr><th>lord</th><th>kingdom</th><th>what for</th><th>waiting</th><th /></tr></thead>
          <tbody>
            {v.lords.map((r) => (
              <tr key={r.player_id}>
                <td>
                  <b>{r.name ?? "a lord who has gone"}</b>{" "}
                  <span className="u-faint">{r.username}</span>
                  {r.level ? <span className="u-faint"> · Lv {r.level}</span> : null}
                  {r.state && r.state !== "active" ? <Pill tone="bad">{r.state}</Pill> : null}
                  {r.muted_for ? <Pill tone="warn">silent {ago(r.muted_for)}</Pill> : null}
                </td>
                <td className="u-faint">{r.kingdom ?? "—"}</td>
                <td><Pill tone="neutral">{r.reports}× {r.reasons || "reported"}</Pill></td>
                <td>
                  <Pill tone={r.waiting_for > 86400 ? "warn" : "neutral"} dot>
                    {ago(r.waiting_for)}
                  </Pill>
                </td>
                <td>
                  {canJudge ? (
                    <>
                      <Button variant="danger" onClick={() => void mute(r, v.mute_minutes)}>
                        silence an hour
                      </Button>
                      <Button onClick={() => void clear(r)}>looked at</Button>
                    </>
                  ) : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}

/* ----------------------------------------------------------- the silences --- */

function MutesPanel({ canJudge }: { canJudge: boolean }) {
  const mutate = useMutate();
  const [rows, setRows] = useState<Mute[] | null>(null);

  const load = useCallback(async () => {
    const res = await query<{ mutes: Mute[] }>("modMutes", { limit: 50 });
    setRows(res.ok ? res.data.mutes : []);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function lift(m: Mute) {
    const res = await mutate("modUnmute", { player_id: m.player_id, note: "" }, {
      key: "unmute:" + m.player_id, success: `${m.name} may speak again`,
    });
    if (res.ok) await load();
  }

  if (!rows) return <Panel title="Silences"><Skeleton h={100} /></Panel>;
  return (
    <Panel title="Silences" flush>
      <p className={s.lede}>
        Every silence and who ordered it &mdash; three blocked words inside the hall&rsquo;s window
        order one by themselves, and those say <b>auto</b>. Lifting one also forgets the strikes
        behind it: a lord who is let back in starts again.
      </p>
      {rows.length === 0 ? (
        <EmptyState title="Nobody has been silenced." />
      ) : (
        <table className="u-table">
          <thead><tr><th>lord</th><th>by</th><th>why</th><th>until</th><th /></tr></thead>
          <tbody>
            {rows.map((m) => (
              <tr key={m.player_id + m.at}>
                <td><b>{m.name}</b> <span className="u-faint">{m.username}</span></td>
                <td>{m.by === "auto" ? <Pill tone="neutral">auto</Pill> : m.by}</td>
                <td className="u-faint">{m.reason}</td>
                <td>{m.live ? <Pill tone="warn" dot>live</Pill> : <span className="u-faint">lapsed</span>}</td>
                <td>
                  {canJudge && m.live ? <Button onClick={() => void lift(m)}>let them speak</Button> : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}
