"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Skeleton, Stat, Stats } from "@/ui/kit";
import { num } from "@/lib/format";
import s from "./depth.module.css";

// PvE ve derinlik (Wave 7) at the desk: the Conquest Campaign's road across the
// realm, the expeditions out on it, the anvil's work and the tree's picks.
//
// A READ, and only a read. There is no lever on this page on purpose: a stage's
// garrison, a field's wages and a talent's rank are all decided in the balance,
// where Validate holds them and the Balance page publishes them. What an
// operator needs here is to SEE whether the road is walked, whether the roads
// are used, whether the anvil burns what it was meant to, and which three
// talents the realm thinks are the only ones worth taking.

type Chapter = { id: string; name: string; lords: number; stages: number; stars: number; walks: number };
type Field = { id: string; name: string; away: number; at_gate: number };
type Forged = { tier: string; made: number };
type Pick = { id: string; name: string; branch: string; lords: number; ranks: number };
type Depth = {
  chapters: Chapter[]; walks: number; first_clears: number;
  fields: Field[]; home: number; recalled: number; gold_wages: number; xp_wages: number;
  forged: Forged[]; forge_gold: number;
  talents: Pick[]; respecs: number; rethinks: number;
  window_hours: number;
};

const WINDOWS = [24, 72, 168];

export function DepthView() {
  const [v, setV] = useState<Depth | null>(null);
  const [hours, setHours] = useState(24);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<Depth>("depth", { hours });
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, [hours]);
  useEffect(() => { void load(); }, [load]);

  if (error) return <Panel title="Derinlik"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="Derinlik"><Skeleton h={160} /></Panel>;

  const span = v.window_hours === 24 ? "today" : `the last ${v.window_hours} hours`;
  const away = v.fields.reduce((n, f) => n + f.away, 0);
  const waiting = v.fields.reduce((n, f) => n + f.at_gate, 0);
  return (
    <div className={s.page}>
      <Panel title="The Conquest Campaign" flush>
        <p className={s.lede}>
          Where the realm stands on the road. A mile is written down, not rolled: what changes
          here is how far lords have walked, never how hard a garrison is — that is
          campaign.json, and the Balance page is where it moves.
        </p>
        <div className={s.actions}>
          {WINDOWS.map((h) => (
            <Button key={h} variant={h === hours ? "primary" : "quiet"} size="sm" onClick={() => setHours(h)}>
              {h === 24 ? "today" : `${h}h`}
            </Button>
          ))}
        </div>
        <Stats>
          <Stat label={`miles walked ${span}`} value={num(v.walks)} />
          <Stat label={`first clears ${span}`} value={num(v.first_clears)} />
          <Stat label="lords on the road" value={num(v.chapters.reduce((n, c) => Math.max(n, c.lords), 0))} />
          <Stat label="stars held" value={num(v.chapters.reduce((n, c) => n + c.stars, 0))} />
        </Stats>
        <table className="u-table">
          <thead><tr><th>chapter</th><th className={s.num}>lords</th>
            <th className={s.num}>miles cleared</th><th className={s.num}>stars</th>
            <th className={s.num}>walks</th></tr></thead>
          <tbody>
            {v.chapters.map((c) => (
              <tr key={c.id}>
                <td><b>{c.name}</b> <span className="u-faint">{c.id}</span></td>
                <td className={s.num}>{num(c.lords)}</td>
                <td className={s.num}>{num(c.stages)}</td>
                <td className={s.num}>{num(c.stars)}</td>
                <td className={s.num}>{num(c.walks)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      <Panel title="The roads" flush>
        <p className={s.lede}>
          An expedition costs no energy at all, so what it costs is the soldier: away, they do not
          fight in their lord&apos;s own battles. The wages are the balance&apos;s own units — what that
          much energy earns at the lord&apos;s best job — and a recall pays nothing.
        </p>
        <Stats>
          <Stat label="soldiers away" value={num(away)} />
          <Stat label="at the gate" value={num(waiting)}
            title="Home, with a haul nobody has let in yet." />
          <Stat label={`came home ${span}`} value={num(v.home)} />
          <Stat label={`called back ${span}`} value={num(v.recalled)} muted={v.recalled > v.home} />
          <Stat label="wages paid" value={`${num(v.gold_wages)}g · ${num(v.xp_wages)}xp`} />
        </Stats>
        <div className={s.bands}>
          {v.fields.map((f) => (
            <span key={f.id} className={s.band}>{f.name} <b>{num(f.away)}</b>
              {f.at_gate > 0 ? ` · ${num(f.at_gate)} waiting` : ""}</span>
          ))}
        </div>
      </Panel>

      <Panel title="The forge" flush>
        <p className={s.lede}>
          Three pieces of one slot and rank and gold make one of the rank above. The fee is the
          sink: it is a larger share of the next rank&apos;s price than selling pays back, so forging
          and selling always loses — what this watches is whether the gold is actually burning.
        </p>
        <Stats>
          <Stat label={`pieces made ${span}`} value={num(v.forged.reduce((n, f) => n + f.made, 0))} />
          <Stat label={`gold burnt ${span}`} value={num(v.forge_gold)} />
        </Stats>
        {v.forged.length === 0 ? (
          <EmptyState title="The anvil has been cold." />
        ) : (
          <div className={s.bands}>
            {v.forged.map((f) => (
              <span key={f.tier} className={s.band}>{f.tier} <b>{num(f.made)}</b></span>
            ))}
          </div>
        )}
      </Panel>

      <Panel title="The talent tree" flush>
        <p className={s.lede}>
          Twenty-seven points against fifty-one ranks, so the tree is a choice. If one branch takes
          every lord, the choice is not a choice — that is what this list is for.
        </p>
        <Stats>
          <Stat label="lords who changed their mind" value={num(v.rethinks)} />
          <Stat label="respecs bought" value={num(v.respecs)} />
        </Stats>
        {v.talents.length === 0 ? (
          <EmptyState title="Nobody has spent a point yet." />
        ) : (
          <table className="u-table">
            <thead><tr><th>talent</th><th>branch</th><th className={s.num}>lords</th>
              <th className={s.num}>ranks</th></tr></thead>
            <tbody>
              {v.talents.map((t) => (
                <tr key={t.id}>
                  <td><b>{t.name}</b> <span className="u-faint">{t.id}</span></td>
                  <td className={s.mono}>{t.branch}</td>
                  <td className={s.num}>{num(t.lords)}</td>
                  <td className={s.num}>{num(t.ranks)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
    </div>
  );
}
